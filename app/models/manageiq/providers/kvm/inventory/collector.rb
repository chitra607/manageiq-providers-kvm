require "libvirt"
require "nokogiri"
require "json"
require "resolv"
require "ipaddr"

class ManageIQ::Providers::Kvm::Inventory::Collector < ManageIQ::Providers::Inventory::Collector
  GUEST_AGENT_TIMEOUT = 5   # seconds per guest-agent call (0 = no wait, -1 = default, -2 = block forever)
  CPU_SAMPLE_INTERVAL = 1.0 # seconds — ONE sample window for all running VMs together

  # libvirt virDomainState
  DOMAIN_RUNNING = 1
  DOMAIN_BLOCKED = 2
  DOMAIN_PAUSED  = 3

  # virDomainMemoryStatTags
  MEM_STAT_UNUSED         = 4
  MEM_STAT_AVAILABLE      = 5
  MEM_STAT_ACTUAL_BALLOON = 6
  MEM_STAT_RSS            = 7

  def collect
    inventory
  ensure
    disconnect
  end

  def hosts
    inventory[:hosts]
  end

  def storage_pools
    inventory[:storage_pools]
  end

  def storage_volumes
    inventory[:storage_volumes]
  end

  def networks
    inventory[:networks]
  end

  def vms
    inventory[:vms]
  end

  def connection
    @connection ||= manager.connect
  end

  def disconnect
    manager.disconnect(@connection) if @connection
  ensure
    @connection = nil
  end

  private

  def inventory
    @inventory ||= begin
      _log.info("#{log_header} Collecting inventory...")
      domains          = connection.list_all_domains
      pools, volumes   = collect_storage
      domain_xml_docs  = domains.map { |d| safe_xml(d) }
      dhcp_ip_map      = {}
      nets             = collect_networks(domain_xml_docs, dhcp_ip_map)
      vms              = collect_vms(domains, domain_xml_docs, dhcp_ip_map)

      result = {
        :hosts           => [collect_host],
        :storage_pools   => pools,
        :storage_volumes => volumes,
        :networks        => nets,
        :vms             => vms
      }
      _log.info("#{log_header} Collected #{vms.size} VMs, #{pools.size} storage pools, " \
                "#{volumes.size} volumes, #{nets.size} networks")
      result
    end
  end

  def log_header
    "KVM [#{manager.name}] id [#{manager.id}]:"
  end

  # ---------------------------------------------------------------------------
  # Host (KVM is a single-hypervisor provider: the provider endpoint IS the host)
  # ---------------------------------------------------------------------------
  def collect_host
    node_info = connection.node_info
    caps      = Nokogiri::XML(connection.capabilities)
    sysinfo   = begin
      Nokogiri::XML(connection.sys_info)
    rescue Libvirt::Error, NoMethodError
      nil
    end

    hostname  = connection.hostname
    nodes     = [node_info.nodes.to_i, 1].max
    sockets   = [node_info.sockets.to_i, 1].max * nodes # node_info.sockets is "per NUMA node"
    cores     = [node_info.cores.to_i, 1].max
    threads   = [node_info.threads.to_i, 1].max
    vmm_buildnumber = begin
      format_libvirt_version(connection.libversion)
    rescue Libvirt::Error
      nil
    end

    {
      :ems_ref              => hostname,
      :uid_ems              => caps.at_xpath("//host/uuid")&.text,
      :name                 => hostname,
      :hostname             => hostname,
      :ipaddress            => host_ip_address,
      :vmm_vendor           => "redhat",
      :vmm_product          => connection.type || "QEMU",
      :vmm_version          => format_libvirt_version(connection.version),
      :vmm_buildnumber      => vmm_buildnumber,
      :memory_bytes         => node_info.memory.to_i * 1024, # node_info.memory is KiB
      :cpu_sockets          => sockets,
      :cpu_cores_per_socket => cores,
      :cpu_total_cores      => sockets * cores,
      :cpu_threads          => threads,
      :cpu_speed            => node_info.mhz.to_i,
      :cpu_type             => caps.at_xpath("//host/cpu/model")&.text || node_info.model,
      :cpu_arch             => caps.at_xpath("//host/cpu/arch")&.text,
      :manufacturer         => sysinfo&.at_xpath("//system/entry[@name='manufacturer']")&.text,
      :model                => sysinfo&.at_xpath("//system/entry[@name='product']")&.text,
      :serial_number        => sysinfo&.at_xpath("//system/entry[@name='serial']")&.text,
    }
  end

  def host_ip_address
    address = manager.ipaddress.presence || manager.hostname
    return address if address.blank? || address.to_s.match?(Resolv::IPv4::Regex) || address.to_s.match?(Resolv::IPv6::Regex)

    Resolv.getaddress(address)
  rescue Resolv::ResolvError
    address
  end

  # ---------------------------------------------------------------------------
  # Storage pools + volumes (one pass, one xml_desc per object)
  # ---------------------------------------------------------------------------
  def collect_storage
    pools   = []
    volumes = []

    connection.list_all_storage_pools.each do |pool|
      pool_hash = parse_storage_pool(pool)
      next if pool_hash.nil?

      pools << pool_hash
      next unless pool_hash[:active]

      begin
        pool.list_all_volumes.each do |vol|
          vol_hash = parse_storage_volume(vol, pool_hash)
          volumes << vol_hash if vol_hash
        end
      rescue Libvirt::Error => err
        _log.warn("#{log_header} could not list volumes of pool #{pool_hash[:name]}: #{err.message}")
      end
    end

    [pools, volumes]
  end

  def parse_storage_pool(pool)
    xml      = Nokogiri::XML(pool.xml_desc)
    info     = pool.info
    raw_type = xml.at_xpath("/pool")&.[]("type") || "dir"

    {
      :ems_ref     => pool.uuid,
      :name        => pool.name,
      :raw_type    => raw_type,
      :store_type  => raw_type, # libvirt pool type: dir, fs, netfs, disk, iscsi, logical, rbd, ...
      :total_space => info.capacity,
      :free_space  => info.available,
      :used_space  => info.allocation,
      :location    => xml.at_xpath("/pool/target/path")&.text.presence ||
        xml.at_xpath("/pool/source/host")&.[]("name").presence ||
        pool.name,
      :source_host => xml.at_xpath("/pool/source/host")&.[]("name"),
      :source_path => xml.at_xpath("/pool/source/dir")&.[]("path") ||
        xml.at_xpath("/pool/source/device")&.[]("path"),
      :active      => safe_bool { pool.active? },
      :autostart   => safe_bool { pool.autostart? },
    }
  rescue Libvirt::Error => err
    _log.warn("#{log_header} could not read storage pool: #{err.message}")
    nil
  end

  def parse_storage_volume(vol, pool_hash)
    xml  = Nokogiri::XML(vol.xml_desc)
    info = vol.info

    {
      :ems_ref       => vol.key,
      :name          => vol.name,
      :path          => vol.path,
      :pool_ems_ref  => pool_hash[:ems_ref],
      :pool_name     => pool_hash[:name],
      :format_type   => xml.at_xpath("/volume/target/format")&.[]("type") || "raw",
      :size          => info.capacity,
      :size_on_disk  => info.allocation,
      :backing_store => xml.at_xpath("/volume/backingStore/path")&.text,
    }
  rescue Libvirt::Error => err
    _log.warn("#{log_header} could not read a volume of pool #{pool_hash[:name]}: #{err.message}")
    nil
  end

  def collect_networks(domain_xml_docs, dhcp_ip_map)
    connection.list_all_networks.filter_map do |net|
      xml     = Nokogiri::XML(net.xml_desc)
      ip_node = xml.at_xpath("/network/ip[not(@family) or @family='ipv4']")
      name    = net.name
      active  = safe_bool { net.active? }

      ports = domain_xml_docs.compact.sum do |doc|
        doc.xpath("//devices/interface[@type='network']/source").count { |s| s["network"] == name }
      end

      collect_dhcp_leases(net, dhcp_ip_map) if active

      {
        :ems_ref      => net.uuid,
        :name         => name,
        :forward_mode => xml.at_xpath("/network/forward")&.[]("mode") || "isolated",
        :bridge       => xml.at_xpath("/network/bridge")&.[]("name"),
        :ip_address   => ip_node&.[]("address"),
        :netmask      => ip_node&.[]("netmask") || prefix_to_netmask(ip_node&.[]("prefix")),
        :dhcp_start   => ip_node&.at_xpath("dhcp/range")&.[]("start"),
        :dhcp_end     => ip_node&.at_xpath("dhcp/range")&.[]("end"),
        :mtu          => xml.at_xpath("/network/mtu")&.[]("size")&.to_i,
        :active       => active,
        :persistent   => safe_bool { net.persistent? },
        :ports        => ports,
      }
    rescue Libvirt::Error => err
      _log.warn("#{log_header} could not read network: #{err.message}")
      nil
    end
  end

  def collect_dhcp_leases(net, dhcp_ip_map)
    return unless net.respond_to?(:dhcp_leases)

    net.dhcp_leases.each do |lease|
      mac = lease["mac"].to_s.downcase
      ip  = lease["ipaddr"].to_s
      next if mac.blank? || ip.blank?

      (dhcp_ip_map[mac] ||= []) << ip
    end
  rescue Libvirt::Error => err
    _log.debug("#{log_header} no DHCP leases for network #{net.name}: #{err.message}")
  end

  # ---------------------------------------------------------------------------
  # VMs (libvirt domains, running and stopped)
  # ---------------------------------------------------------------------------
  def collect_vms(domains, domain_xml_docs, dhcp_ip_map)
    cpu_usage = sample_cpu_usage(domains)

    domains.each_with_index.filter_map do |domain, idx|
      doc = domain_xml_docs[idx]
      next if doc.nil? # domain vanished while we were collecting

      collect_vm(domain, doc, cpu_usage, dhcp_ip_map)
    rescue Libvirt::Error => err
      _log.warn("#{log_header} skipping domain #{safe_name(domain)}: #{err.message}")
      nil
    end
  end

  def collect_vm(domain, doc, cpu_usage, dhcp_ip_map)
    uuid       = domain.uuid
    state      = domain.state.first.to_i
    running    = [DOMAIN_RUNNING, DOMAIN_BLOCKED, DOMAIN_PAUSED].include?(state)
    agent_ok   = running && state != DOMAIN_PAUSED

    guest_ifaces = agent_ok ? guest_agent(domain, "guest-network-get-interfaces") : nil
    guest_os     = agent_ok ? guest_agent(domain, "guest-get-osinfo") : nil
    guest_host   = agent_ok ? guest_agent(domain, "guest-get-host-name")&.dig("host-name") : nil

    {
      :uuid            => uuid,
      :name            => domain.name,
      :state           => state,
      :xml             => doc,
      :persistent      => safe_bool { domain.persistent? },
      :autostart       => safe_bool { domain.autostart? },
      :ip_addresses    => vm_ip_addresses(guest_ifaces, doc, dhcp_ip_map),
      :guest_ifaces    => guest_iface_names(guest_ifaces),
      :guest_os        => guest_os,
      :guest_hostname  => guest_host,
      :cpu_usage       => cpu_usage[uuid],
      :memory_usage_mb => running ? memory_usage_mb(domain) : nil,
      :block_info      => block_info(domain, doc),
      :snapshots       => collect_snapshots(domain),
    }
  end

  def safe_xml(domain)
    Nokogiri::XML(domain.xml_desc)
  rescue Libvirt::Error => err
    _log.warn("#{log_header} could not read XML of domain #{safe_name(domain)}: #{err.message}")
    nil
  end

  # CPU % for every running domain using ONE shared sample window
  # (previously the parser slept 1 s per VM: 300 VMs = 5 minutes of sleeping).
  def sample_cpu_usage(domains)
    first = domains.each_with_object({}) do |domain, h|
      info = domain.info
      next unless info.state.to_i == DOMAIN_RUNNING

      h[domain.uuid] = [info.cpu_time.to_i, [info.nr_virt_cpu.to_i, 1].max, monotonic_now]
    rescue Libvirt::Error
      next
    end
    return {} if first.empty?

    sleep(CPU_SAMPLE_INTERVAL)

    domains.each_with_object({}) do |domain, h|
      t1, vcpus, s1 = first[domain.uuid]
      next if t1.nil?

      t2         = domain.info.cpu_time.to_i
      wall_ns    = (monotonic_now - s1) * 1_000_000_000.0
      next if wall_ns <= 0

      h[domain.uuid] = ((t2 - t1) / (wall_ns * vcpus) * 100.0).clamp(0.0, 100.0).round(2)
    rescue Libvirt::Error
      next
    end
  end

  def memory_usage_mb(domain)
    # stats = domain.memory_stats.each_with_object({}) { |s, h| h[s.tag.to_i] = s.val.to_i }
    stats = domain.memory_stats.to_h { |s| [s.tag.to_i, s.instance_variable_get(:@val).to_i] }

    used_kib = if stats[MEM_STAT_ACTUAL_BALLOON] && stats[MEM_STAT_UNUSED]
                 stats[MEM_STAT_ACTUAL_BALLOON] - stats[MEM_STAT_UNUSED]
               elsif stats[MEM_STAT_AVAILABLE] && stats[MEM_STAT_UNUSED]
                 stats[MEM_STAT_AVAILABLE] - stats[MEM_STAT_UNUSED]
               else
                 stats[MEM_STAT_RSS] # host-side resident size as last resort
               end
    used_kib.to_i.positive? ? used_kib / 1024 : nil
  rescue Libvirt::Error, NoMethodError
    nil
  end

  def block_info(domain, doc)
    doc.xpath("//devices/disk[@device='disk']/target").each_with_object({}) do |target, h|
      dev = target["dev"]
      next if dev.blank?

      info = domain.blockinfo(dev)
      h[dev] = {:capacity => info.capacity.to_i, :allocation => info.allocation.to_i}
    rescue Libvirt::Error, NoMethodError
      next
    end
  end

  def collect_snapshots(domain)
    current_name = begin
      domain.has_current_snapshot? ? domain.current_snapshot.name : nil
    rescue Libvirt::Error, NoMethodError
      nil
    end

    domain.list_all_snapshots.map do |snap|
      {
        :name    => snap.name,
        :xml     => snap.xml_desc,
        :current => snap.name == current_name
      }
    end
  rescue Libvirt::Error => err
    _log.warn("#{log_header} could not list snapshots of #{safe_name(domain)}: #{err.message}")
    []
  end

  def guest_agent(domain, command)
    return nil unless domain.respond_to?(:qemu_agent_command)

    response = domain.qemu_agent_command({:execute => command}.to_json, GUEST_AGENT_TIMEOUT, 0)
    JSON.parse(response)["return"]
  rescue Libvirt::Error, JSON::ParserError => err
    _log.debug("#{log_header} guest agent #{command} failed for #{safe_name(domain)}: #{err.message}")
    nil
  end

  # { "52:54:00:68:24:59" => ["192.168.122.95", "fd00::5"] }
  def vm_ip_addresses(guest_ifaces, doc, dhcp_ip_map)
    result = Hash.new { |h, k| h[k] = [] }

    Array(guest_ifaces).each do |iface|
      next if iface["name"] == "lo"

      mac = iface["hardware-address"].to_s.downcase
      next if mac.blank?

      Array(iface["ip-addresses"]).each do |ip|
        address = ip["ip-address"].to_s
        next if address.blank? || address.start_with?("127.", "::1", "fe80")

        result[mac] << address
      end
    end

    # Fallback: libvirt DHCP leases for NICs the guest agent did not report.
    doc.xpath("//devices/interface/mac").each do |mac_node|
      mac = mac_node["address"].to_s.downcase
      next if mac.blank? || result.key?(mac) || dhcp_ip_map[mac].blank?

      result[mac].concat(dhcp_ip_map[mac])
    end

    result.transform_values(&:uniq).to_h
  end

  def guest_iface_names(guest_ifaces)
    Array(guest_ifaces).each_with_object({}) do |iface, h|
      mac = iface["hardware-address"].to_s.downcase
      h[mac] = iface["name"] if mac.present?
    end
  end

  def format_libvirt_version(ver_int)
    ver_int = ver_int.to_i
    "#{ver_int / 1_000_000}.#{(ver_int / 1_000) % 1_000}.#{ver_int % 1_000}"
  end

  def prefix_to_netmask(prefix)
    return nil if prefix.blank?

    IPAddr.new("255.255.255.255").mask(prefix.to_i).to_s
  rescue ArgumentError
    nil
  end

  def safe_bool
    yield ? true : false
  rescue Libvirt::Error, NoMethodError
    false
  end

  def safe_name(domain)
    domain.name
  rescue Libvirt::Error
    "(unknown)"
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

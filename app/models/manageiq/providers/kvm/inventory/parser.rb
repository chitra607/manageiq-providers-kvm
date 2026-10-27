require "nokogiri"

class ManageIQ::Providers::Kvm::Inventory::Parser < ManageIQ::Providers::Inventory::Parser
  POWER_STATES = {
    0 => "unknown",
    1 => "on",
    2 => "on",
    3 => "paused",
    4 => "off", # "being shut down" — guest is going down
    5 => "off",
    6 => "unknown",
    7 => "suspended",
  }.freeze

  TEMPLATE_FORMATS = %w[qcow2 raw].freeze

  def parse
    host
    storage_pools
    storage_volumes
    host_storages
    virtual_networks
    vms
    templates if discover_templates?
  end

  def host
    h = collector.hosts.first

    @host = persister.hosts.build(
      :ems_ref          => h[:ems_ref],
      :uid_ems          => h[:uid_ems],
      :name             => h[:name],
      :hostname         => h[:hostname],
      :ipaddress        => h[:ipaddress],
      :vmm_vendor       => h[:vmm_vendor],
      :vmm_product      => h[:vmm_product],
      :vmm_version      => h[:vmm_version],
      :vmm_buildnumber  => h[:vmm_buildnumber],
      :power_state      => "on",
      :connection_state => "connected",
      :hyperthreading   => h[:cpu_threads].to_i > 1,
      :type             => "ManageIQ::Providers::Kvm::InfraManager::Host"
    )

    persister.host_hardwares.build(
      :host                 => @host,
      :cpu_sockets          => h[:cpu_sockets],
      :cpu_cores_per_socket => h[:cpu_cores_per_socket],
      :cpu_total_cores      => h[:cpu_total_cores],
      :cpu_speed            => h[:cpu_speed],
      :cpu_type             => h[:cpu_type],
      :manufacturer         => h[:manufacturer],
      :model                => h[:model],
      :serial_number        => h[:serial_number],
      :memory_mb            => h[:memory_bytes].to_i / 1.megabyte
    )

    # libvirt does not expose the host OS release; a KVM hypervisor is Linux.
    persister.host_operating_systems.build(
      :host         => @host,
      :name         => h[:hostname],
      :product_name => ["Linux", h[:cpu_arch]].compact.join(" "),
      :product_type => "linux"
    )
  end

  def storage_pools
    collector.storage_pools.each do |pool|
      persister.storages.build(
        :ems_ref     => pool[:ems_ref],
        :name        => pool[:name],
        :store_type  => pool[:store_type],
        :total_space => pool[:total_space],
        :free_space  => pool[:free_space],
        :location    => pool[:location]
      )
    end
  end

  def storage_volumes
    collector.storage_volumes.each do |vol|
      attached_vm = vm_by_disk_path[vol[:path]]

      persister.storage_files.build(
        :storage        => persister.storages.lazy_find(vol[:pool_ems_ref]),
        :name           => vol[:path],
        :base_name      => vol[:name],
        :ext_name       => File.extname(vol[:name].to_s).delete_prefix("."),
        :size           => vol[:size],
        :rsc_type       => "file",
        :vm_or_template => attached_vm ? persister.vms.lazy_find(attached_vm) : nil
      )
    end
  end

  # Every pool lives on the (single) KVM host
  def host_storages
    collector.storage_pools.each do |pool|
      persister.host_storages.build(
        :host    => @host,
        :storage => persister.storages.lazy_find(pool[:ems_ref])
      )
    end
  end

  def virtual_networks
    collector.networks.each do |net|
      switch = persister.host_virtual_switches.build(
        :host        => @host,
        :uid_ems     => net[:ems_ref],
        :switch_uuid => net[:ems_ref],
        :name        => net[:name],
        :type        => "ManageIQ::Providers::Kvm::InfraManager::Switch",
        :shared      => true,
        :ports       => net[:ports],
        :mtu         => net[:mtu],
        :power_state => net[:active] ? "on" : "off"
      )

      persister.host_virtual_lans.build(
        :switch  => switch,
        :uid_ems => net[:ems_ref],
        :ems_ref => net[:ems_ref],
        :name    => net[:name],
        :tag     => net[:bridge] # host bridge device, e.g. "virbr0"
      )

      persister.host_switches.build(:host => @host, :switch => switch)
    end
  end

  def vms
    collector.vms.each { |vm| parse_vm(vm) }
  end

  private

  def parse_vm(vm_data)
    xml   = vm_data[:xml]
    disks = disk_sources(xml)

    primary_path = disks.detect { |d| d[:device] == "disk" }&.dig(:path)
    vm_pool_refs = disks.filter_map { |d| volume_for(d)&.dig(:pool_ems_ref) }.uniq
    primary_ref  = primary_path && volume_for(disks.detect { |d| d[:path] == primary_path })&.dig(:pool_ems_ref)

    vm = persister.vms.build(
      :ems_ref          => vm_data[:uuid],
      :uid_ems          => vm_data[:uuid],
      :name             => vm_data[:name],
      :vendor           => "redhat",
      :location         => primary_path.presence || "unknown",
      :raw_power_state  => POWER_STATES.fetch(vm_data[:state], "unknown"),
      :connection_state => "connected",
      :template         => false,
      :type             => "ManageIQ::Providers::Kvm::InfraManager::Vm",
      :host             => @host,
      :storage          => primary_ref ? persister.storages.lazy_find(primary_ref) : nil,
      :storages         => vm_pool_refs.map { |ref| persister.storages.lazy_find(ref) }
    )

    os_info = guest_os_info(vm_data, xml)

    persister.operating_systems.build(
      :vm_or_template => vm,
      :name           => vm_data[:guest_hostname].presence || vm_data[:name],
      :product_name   => os_info[:product_name],
      :distribution   => os_info[:distribution],
      :version        => os_info[:version],
      :kernel_version => os_info[:kernel_version]
    )

    hardware = persister.hardwares.build(vm_hardware_attributes(vm, vm_data, xml, os_info))

    parse_disks(hardware, xml, vm_data[:block_info])
    parse_nics(hardware, xml, vm_data)
    parse_snapshots(vm, vm_data[:snapshots])
  end

  def vm_hardware_attributes(vm, vm_data, xml, os_info)
    vcpu_node  = xml.at_xpath("/domain/vcpu")
    vcpus      = (vcpu_node&.[]("current") || vcpu_node&.text).to_i
    vcpus      = 1 unless vcpus.positive?
    topology   = xml.at_xpath("/domain/cpu/topology")
    sockets    = topology&.[]("sockets").to_i
    cores      = topology&.[]("cores").to_i
    memory_kib = (xml.at_xpath("/domain/currentMemory")&.text || xml.at_xpath("/domain/memory")&.text).to_i
    firmware   = xml.at_xpath("/domain/os")&.[]("firmware") ||
                 (xml.at_xpath("/domain/os/loader").present? ? "efi" : "bios")

    {
      :vm_or_template       => vm,
      :cpu_total_cores      => vcpus,
      :cpu_speed            => collector.hosts.first[:cpu_speed],
      :cpu_sockets          => sockets.positive? ? sockets : vcpus,
      :cpu_cores_per_socket => cores.positive? ? cores : 1,
      :memory_mb            => memory_kib / 1024,
      :cpu_usage            => vm_data[:cpu_usage],
      :memory_usage         => vm_data[:memory_usage_mb],
      :guest_os             => os_info[:distribution],
      :guest_os_full_name   => os_info[:product_name],
      :firmware_type        => firmware,
      :disk_capacity        => disk_sources(xml).select { |d| d[:device] == "disk" }.sum { |d| disk_size(d, vm_data[:block_info])[0] },
      :number_of_nics       => xml.xpath("/domain/devices/interface").size
    }
  end

  def parse_disks(hardware, xml, block_info)
    disk_sources(xml).each_with_index do |d, idx|
      vol              = volume_for(d)
      size, allocation = disk_size(d, block_info)

      persister.disks.build(
        :hardware        => hardware,
        :device_name     => d[:target_dev],
        :device_type     => d[:device],
        :location        => idx.to_s,
        :controller_type => d[:bus] || "virtio",
        :filename        => d[:path],
        :mode            => d[:readonly] ? "readonly" : "writeable",
        :disk_type       => d[:driver_type] || "raw",
        :format          => d[:driver_type] || (d[:device] == "cdrom" ? "iso" : "raw"),
        :thin            => d[:driver_type] == "qcow2",
        :ems_ref         => d[:alias] || "disk-#{idx}",
        :size            => size,
        :size_on_disk    => allocation,
        :present         => true,
        :storage         => vol ? persister.storages.lazy_find(vol[:pool_ems_ref]) : nil
      )
    end
  end

  def disk_size(disk, block_info)
    vol = volume_for(disk)
    return [vol[:size].to_i, vol[:size_on_disk].to_i] if vol

    info = block_info.to_h[disk[:target_dev]]
    info ? [info[:capacity].to_i, info[:allocation].to_i] : [0, 0]
  end

  # One hash per <disk> element of the domain XML
  def disk_sources(xml)
    @disk_sources ||= {}.compare_by_identity
    @disk_sources[xml] ||= xml.xpath("/domain/devices/disk").filter_map do |disk_xml|
      target_dev = disk_xml.at_xpath("target")&.[]("dev")
      next if target_dev.blank?

      source = disk_xml.at_xpath("source")
      {
        :target_dev  => target_dev,
        :device      => disk_xml["device"] || "disk",
        :type        => disk_xml["type"],
        :bus         => disk_xml.at_xpath("target")&.[]("bus"),
        :driver_type => disk_xml.at_xpath("driver")&.[]("type"),
        :alias       => disk_xml.at_xpath("alias")&.[]("name"),
        :readonly    => disk_xml.at_xpath("readonly").present?,
        :path        => source&.[]("file") || source&.[]("dev") || network_disk_path(source) || volume_disk_path(source),
        :pool        => source&.[]("pool"),
        :volume      => source&.[]("volume"),
      }
    end
  end

  def network_disk_path(source)
    return nil if source.nil? || source["protocol"].blank?

    "#{source["protocol"]}://#{source["name"]}"
  end

  def volume_disk_path(source)
    return nil if source.nil? || source["pool"].blank? || source["volume"].blank?

    volume_index_by_pool_and_name[[source["pool"], source["volume"]]]&.dig(:path) ||
      "#{source["pool"]}/#{source["volume"]}"
  end

  def volume_for(disk)
    return nil if disk.nil?

    volume_index_by_path[disk[:path]] ||
      (disk[:pool] && volume_index_by_pool_and_name[[disk[:pool], disk[:volume]]])
  end

  def volume_index_by_path
    @volume_index_by_path ||= collector.storage_volumes.index_by { |v| v[:path] }
  end

  def volume_index_by_pool_and_name
    @volume_index_by_pool_and_name ||= collector.storage_volumes.index_by { |v| [v[:pool_name], v[:name]] }
  end

  # disk path → VM uuid, used to link StorageFile records to their VM
  def vm_by_disk_path
    @vm_by_disk_path ||= collector.vms.each_with_object({}) do |vm, map|
      disk_sources(vm[:xml]).each { |d| map[d[:path]] = vm[:uuid] if d[:path] }
    end
  end

  # ---------------------------------------------------------------------------
  # NICs + IP addresses
  # ---------------------------------------------------------------------------
  def parse_nics(hardware, xml, vm_data)
    xml.xpath("/domain/devices/interface").each_with_index do |iface_xml, idx|
      mac        = iface_xml.at_xpath("mac")&.[]("address")&.downcase
      model      = iface_xml.at_xpath("model")&.[]("type")
      target_dev = iface_xml.at_xpath("target")&.[]("dev")
      iface_type = iface_xml["type"]
      source     = iface_xml.at_xpath("source")
      net_name   = source&.[]("network")
      bridge     = source&.[]("bridge")
      direct_dev = source&.[]("dev")
      uid_ems    = mac.presence || "#{vm_data[:uuid]}-nic-#{idx}"
      guest_name = vm_data[:guest_ifaces].to_h[mac]

      nic = persister.guest_devices.build(
        :hardware        => hardware,
        :uid_ems         => uid_ems,
        :device_name     => guest_name || target_dev || "eth#{idx}",
        :device_type     => "ethernet",
        :controller_type => model || "virtio",
        :model           => model || "virtio",
        :mode            => iface_type,
        :address         => mac,
        :present         => true,
        :start_connected => iface_xml.at_xpath("link[@state='down']").nil?,
        :vlan_key        => net_name || bridge || direct_dev,
        :lan             => lan_for(net_name, bridge)
      )

      Array(vm_data[:ip_addresses].to_h[mac]).each do |ip|
        ipv6 = ip.include?(":")
        persister.networks.build(
          :hardware     => hardware,
          :guest_device => nic,
          :ipaddress    => ipv6 ? nil : ip,
          :ipv6address  => ipv6 ? ip : nil,
          :hostname     => vm_data[:guest_hostname],
          :description  => guest_name || "eth#{idx}"
        )
      end
    end
  end

  # Lan of the libvirt network the NIC is plugged into (type='network'), or of
  # the libvirt network that wraps the host bridge (type='bridge').
  def lan_for(net_name, bridge)
    net = network_by_name[net_name] if net_name
    net ||= network_by_bridge[bridge] if bridge
    return nil if net.nil?

    switch = persister.host_virtual_switches.lazy_find(:host => @host, :uid_ems => net[:ems_ref])
    persister.host_virtual_lans.lazy_find({:switch => switch, :uid_ems => net[:ems_ref]}, :transform_nested_lazy_finds => true)
  end

  def network_by_name
    @network_by_name ||= collector.networks.index_by { |n| n[:name] }
  end

  def network_by_bridge
    @network_by_bridge ||= collector.networks.select { |n| n[:bridge] }.index_by { |n| n[:bridge] }
  end

  # ---------------------------------------------------------------------------
  # Snapshots
  # ---------------------------------------------------------------------------
  def parse_snapshots(vm, snapshots)
    Array(snapshots).each do |snap|
      doc         = Nokogiri::XML(snap[:xml])
      name        = snap[:name] || doc.at_xpath("/domainsnapshot/name")&.text
      created     = doc.at_xpath("/domainsnapshot/creationTime")&.text
      parent_name = doc.at_xpath("/domainsnapshot/parent/name")&.text

      persister.snapshots.build(
        :vm_or_template => vm,
        :uid            => name,
        :uid_ems        => name,
        :ems_ref        => name,
        :name           => name,
        :description    => doc.at_xpath("/domainsnapshot/description")&.text,
        :parent_uid     => parent_name,
        :parent         => parent_name ? persister.snapshots.lazy_find(:vm_or_template => vm, :uid => parent_name) : nil,
        :create_time    => created ? Time.at(created.to_i).utc : nil,
        :current        => snap[:current] ? 1 : 0
      )
    end
  end

  def guest_os_info(vm_data, xml)
    agent = vm_data[:guest_os].to_h
    if agent.present?
      return {
        :product_name   => agent["pretty-name"].presence || [agent["name"], agent["version"]].compact.join(" "),
        :distribution   => agent["id"].presence || agent["name"],
        :version        => agent["version-id"] || agent["version"],
        :kernel_version => agent["kernel-release"]
      }
    end

    os_id = xml.at_xpath("/domain/metadata/*[local-name()='libosinfo']/*[local-name()='os']")&.[]("id")
    if os_id.present?
      parts   = URI.parse(os_id).path.to_s.split("/").reject(&:blank?)
      distro  = parts[-2] || parts[-1]
      version = parts.size > 1 ? parts[-1] : nil
      return {
        :product_name   => [distro, version].compact.join(" "),
        :distribution   => distro,
        :version        => version,
        :kernel_version => nil
      }
    end

    {:product_name => "unknown", :distribution => nil, :version => nil, :kernel_version => nil}
  rescue URI::InvalidURIError
    {:product_name => "unknown", :distribution => nil, :version => nil, :kernel_version => nil}
  end

  def templates
    collector.storage_volumes.each do |vol|
      next unless TEMPLATE_FORMATS.include?(vol[:format_type])
      next if vm_by_disk_path.key?(vol[:path])

      storage = persister.storages.lazy_find(vol[:pool_ems_ref])
      tmpl = persister.miq_templates.build(
        :ems_ref         => vol[:ems_ref],
        :uid_ems         => vol[:ems_ref],
        :name            => File.basename(vol[:name].to_s, ".*"),
        :vendor          => "redhat",
        :location        => vol[:path],
        :raw_power_state => "never",
        :template        => true,
        :type            => "ManageIQ::Providers::Kvm::InfraManager::Template",
        :host            => @host,
        :storage         => storage,
        :storages        => [storage]
      )

      hardware = persister.hardwares.build(
        :vm_or_template => tmpl,
        :disk_capacity  => vol[:size],
        :memory_mb      => 0
      )

      persister.disks.build(
        :hardware     => hardware,
        :device_name  => "vda",
        :device_type  => "disk",
        :filename     => vol[:path],
        :format       => vol[:format_type],
        :disk_type    => vol[:format_type],
        :size         => vol[:size],
        :size_on_disk => vol[:size_on_disk],
        :storage      => storage
      )
    end
  end

  def discover_templates?
    persister.respond_to?(:discover_templates?) && persister.discover_templates?
  end
end

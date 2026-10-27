require "nokogiri"
require "securerandom"

class ManageIQ::Providers::Kvm::InfraManager::DomainCloner
  TEMPLATE_NS  = "http://manageiq.org/xmlns/libvirt/kvm/1.0".freeze
  TEMPLATE_KEY = "miq".freeze

  FILE_POOL_TYPES  = %w[dir fs netfs].freeze
  BLOCK_POOL_TYPES = %w[logical disk iscsi iscsi-direct mpath scsi].freeze

  class Error < StandardError; end

  def self.template_xml?(doc)
    doc.at_xpath("/domain/metadata/*[namespace-uri()='#{TEMPLATE_NS}' and local-name()='template']").present?
  end

  def self.destroy_domain(conn, uuid, logger = nil)
    log    = logger || Logger.new(nil)
    domain = conn.lookup_domain_by_uuid(uuid)
    doc    = Nokogiri::XML(domain.xml_desc(Libvirt::Domain::XML_INACTIVE))
    name   = domain.name

    own_paths = doc.xpath("/domain/devices/disk").filter_map do |disk|
      path = disk_source_path(conn, disk)
      next if path.nil?
      next path if disk["device"] == "disk" || disk["device"].nil?

      path if disk["device"] == "cdrom" && path =~ /cidata/i
    end

    users = backing_users(conn, own_paths, uuid)
    raise Error, "Cannot remove [#{name}]: #{users.join(", ")} #{users.size == 1 ? "is a linked clone" : "are linked clones"} of its disk" if users.any?

    domain.destroy if domain.active?
    flags = Libvirt::Domain::UNDEFINE_SNAPSHOTS_METADATA | Libvirt::Domain::UNDEFINE_MANAGED_SAVE | Libvirt::Domain::UNDEFINE_NVRAM
    begin
      domain.undefine(flags)
    rescue Libvirt::Error
      domain.undefine
    end
    log.info("KVM: undefined domain [#{name}] (#{uuid})")

    any_pool = conn.list_all_storage_pools.first
    own_paths.each do |path|
      vol = any_pool.lookup_volume_by_path(path)
      vol.delete
      log.info("KVM: deleted volume #{path}")
    rescue Libvirt::Error => err
      log.warn("KVM: volume #{path} of [#{name}] not deleted: #{err.message}")
    end
    name
  end

  # file / block path of a <disk>, also for type='volume' (pool + volume name)
  def self.disk_source_path(conn, disk)
    source = disk.at_xpath("source")
    return nil if source.nil?
    return source["file"] || source["dev"] unless disk["type"] == "volume"

    conn.lookup_storage_pool_by_name(source["pool"]).lookup_volume_by_name(source["volume"]).path
  rescue Libvirt::Error
    nil
  end

  # Names of other domains whose disks use one of paths as qcow2 backing file
  def self.backing_users(conn, paths, own_uuid)
    return [] if paths.empty?

    any_pool = conn.list_all_storage_pools.first
    conn.list_all_domains.each_with_object([]) do |dom, users|
      next if dom.uuid == own_uuid

      Nokogiri::XML(dom.xml_desc(Libvirt::Domain::XML_INACTIVE)).xpath("//devices/disk").each do |disk|
        path = disk_source_path(conn, disk)
        next if path.nil?

        vol = any_pool.lookup_volume_by_path(path)
        backing = Nokogiri::XML(vol.xml_desc).at_xpath("/volume/backingStore/path")&.text
        if backing && paths.include?(backing)
          users << dom.name
          break
        end
      rescue Libvirt::Error
        next
      end
    end
  end

  attr_reader :conn, :log, :created_volumes

  def initialize(conn, logger = nil)
    @conn            = conn
    @log             = logger || Logger.new(nil)
    @created_volumes = []
  end

  # opts:
  #   :source_uuid     uuid of the domain to copy (VM or template), or
  #   :source_volume   path of a bare disk image (volume template) instead
  #   :name            new domain name (required)
  #   :description     <description> of the new domain
  #   :dest_pool       storage pool name for the new disks (default: each source disk's pool)
  #   :linked          true = qcow2 overlay on the source disks (instant, thin)
  #   :disk_format     "qcow2" / "raw" (default: same as the source disk)
  #   :root_disk_size  bytes; grows the first disk if larger than the source
  #   :vcpus, :sockets, :cores, :memory_mb
  #   :network         {:type => "network" | "bridge", :name => "default"}
  #   :mac             MAC for the first NIC (generated when blank)
  #   :template        true = mark the new domain as a template
  #   :cloud_init      {"user-data" => ..., "meta-data" => ..., "network-config" => ...}
  #   :start           boot the new domain after defining it
  #
  # Returns {:uuid, :name, :mac, :volumes}
  def clone(opts)
    opts = opts.to_h.symbolize_keys
    name = opts[:name].to_s.strip
    raise Error, "Destination VM name is required" if name.empty?
    raise Error, "A domain named [#{name}] already exists on the KVM host" if domain_exists?(name)

    doc = source_document(opts)
    prepare_identity(doc, name, opts)
    clone_disks(doc, name, opts)
    remove_old_seed_cdroms(doc)
    configure_cpu(doc, opts)
    configure_memory(doc, opts[:memory_mb])
    mac = configure_network(doc, opts)
    attach_cloud_init(doc, name, opts) if opts[:cloud_init].present?

    xml    = doc.to_xml
    domain = conn.define_domain_xml(xml)
    @defined_domain = domain
    log.info("KVM clone: defined domain [#{name}] uuid [#{domain.uuid}]")

    domain.create if opts[:start]

    {:uuid => domain.uuid, :name => name, :mac => mac, :volumes => created_volumes.map(&:path), :xml => xml}
  rescue
    cleanup!
    raise
  end

  # Remove everything this cloner created (called automatically on failure).
  def cleanup!
    if @defined_domain
      begin
        @defined_domain.destroy if @defined_domain.active?
      rescue Libvirt::Error
        nil
      end
      begin
        @defined_domain.undefine(Libvirt::Domain::UNDEFINE_NVRAM)
      rescue Libvirt::Error
        @defined_domain.undefine rescue nil # rubocop:disable Style/RescueModifier
      end
      @defined_domain = nil
    end

    created_volumes.reverse_each do |vol|
      path = vol.path rescue nil # rubocop:disable Style/RescueModifier
      vol.delete
      log.info("KVM clone: removed volume #{path}")
    rescue Libvirt::Error => err
      log.warn("KVM clone: could not remove volume #{path}: #{err.message}")
    end
    created_volumes.clear
  end

  # Random locally administered MAC in the QEMU range, unique on this host.
  def generate_mac
    used = used_macs
    loop do
      mac = "52:54:00:%02x:%02x:%02x" % [SecureRandom.random_number(256), SecureRandom.random_number(256), SecureRandom.random_number(256)]
      return mac unless used.include?(mac)
    end
  end

  private

  # --- source -----------------------------------------------------------------

  def source_document(opts)
    if opts[:source_uuid].present?
      domain = conn.lookup_domain_by_uuid(opts[:source_uuid])
      Nokogiri::XML(domain.xml_desc(Libvirt::Domain::XML_INACTIVE), &:noblanks)
    elsif opts[:source_volume].present?
      Nokogiri::XML(bare_domain_xml(opts[:source_volume]), &:noblanks)
    else
      raise Error, "No source VM, template or disk image given"
    end
  rescue Libvirt::RetrieveError
    raise Error, "Source domain #{opts[:source_uuid]} was not found on the KVM host"
  end

  # Minimal domain for a template that is only a disk image
  def bare_domain_xml(path)
    vol = lookup_volume_by_path(path)
    fmt = volume_format(vol) || "qcow2"
    <<~XML
      <domain type='kvm'>
        <name>template</name>
        <memory unit='MiB'>1024</memory>
        <vcpu>1</vcpu>
        <os><type arch='x86_64'>hvm</type><boot dev='hd'/></os>
        <features><acpi/><apic/></features>
        <cpu mode='host-model'/>
        <clock offset='utc'/>
        <devices>
          <disk type='file' device='disk'>
            <driver name='qemu' type='#{fmt}'/>
            <source file='#{xml_escape(vol.path)}'/>
            <target dev='vda' bus='virtio'/>
          </disk>
          <interface type='network'><source network='default'/><model type='virtio'/></interface>
          <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
          <serial type='pty'/>
          <console type='pty'/>
          <graphics type='vnc' port='-1' autoport='yes'/>
          <video><model type='virtio'/></video>
          <memballoon model='virtio'/>
          <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
        </devices>
      </domain>
    XML
  end

  # --- identity ---------------------------------------------------------------

  def prepare_identity(doc, name, opts)
    root = doc.root
    set_child_text(root, "name", name, :first => true)
    root.xpath("uuid|title|genid").each(&:remove)
    root.xpath("sysinfo/system/entry[@name='uuid' or @name='serial']").each(&:remove)

    if opts[:description].present?
      set_child_text(root, "description", opts[:description].to_s, :after => "name")
    else
      root.xpath("description").each(&:remove)
    end

    # Per-VM UEFI variable store: keep the template attribute, drop the path so
    # libvirt creates /var/lib/libvirt/qemu/nvram/<name>_VARS.fd on first boot.
    root.xpath("os/nvram").each do |nvram|
      nvram.children.each(&:remove)
      nvram.remove_attribute("path")
      nvram.xpath("source").each(&:remove)
    end

    # Runtime / per-instance details that must not be copied
    root.xpath("devices/interface/target|devices/interface/alias|devices/*/alias").each(&:remove)
    root.xpath("devices/channel/source[@path]").each { |s| s.remove_attribute("path") }
    root.xpath("devices/graphics").each do |g|
      next if g["autoport"] == "yes" || g["port"].nil?

      g["autoport"] = "yes"
      g.remove_attribute("port")
      g.remove_attribute("websocket")
    end
    root.xpath("devices/disk/serial|devices/disk/wwn").each(&:remove)

    set_template_flag(doc, opts[:template])
  end

  def set_template_flag(doc, template)
    root = doc.root
    root.xpath("metadata/*[namespace-uri()='#{TEMPLATE_NS}']").each(&:remove)
    return unless template

    metadata = root.at_xpath("metadata") || root.add_child(Nokogiri::XML::Node.new("metadata", doc))
    node = Nokogiri::XML::Node.new("template", doc)
    ns   = node.add_namespace_definition(TEMPLATE_KEY, TEMPLATE_NS)
    node.namespace = ns
    metadata.add_child(node)
  end

  # --- disks ------------------------------------------------------------------

  def clone_disks(doc, name, opts)
    disks = doc.xpath("/domain/devices/disk[@device='disk' or not(@device)]")
    raise Error, "The source has no disk to clone" if disks.empty?

    disks.each_with_index do |disk, idx|
      src_vol = disk_volume(disk)
      src_fmt = volume_format(src_vol) || disk.at_xpath("driver")&.[]("type") || "raw"
      pool    = destination_pool(opts[:dest_pool], src_vol)
      ptype   = pool_type(pool)
      linked  = opts[:linked] ? true : false
      raise Error, "Linked clones need a directory-type storage pool; [#{pool.name}] is #{ptype}" if linked && FILE_POOL_TYPES.exclude?(ptype)

      fmt = if linked
              "qcow2"
            elsif BLOCK_POOL_TYPES.include?(ptype)
              "raw"
            else
              opts[:disk_format].presence || src_fmt
            end

      src_capacity = src_vol.info.capacity.to_i
      capacity     = src_capacity
      capacity     = opts[:root_disk_size].to_i if idx.zero? && opts[:root_disk_size].to_i > src_capacity

      vol_name = volume_name(name, disk, idx, fmt, ptype)
      raise Error, "Volume [#{vol_name}] already exists in pool [#{pool.name}]" if volume_exists?(pool, vol_name)

      log.info("KVM clone: #{linked ? "linked" : "full"} copy of #{src_vol.path} -> #{pool.name}/#{vol_name} (#{fmt})")
      new_vol = if linked
                  pool.create_volume_xml(overlay_xml(vol_name, capacity, src_vol.path, src_fmt))
                else
                  pool.create_volume_xml_from(volume_xml(vol_name, src_capacity, fmt, ptype), src_vol)
                end
      created_volumes << new_vol

      if !linked && capacity > src_capacity
        log.info("KVM clone: growing #{new_vol.path} to #{capacity} bytes")
        new_vol.resize(capacity)
      end

      point_disk_at(disk, new_vol, fmt, ptype, pool)
    end
  end

  def disk_volume(disk)
    source = disk.at_xpath("source")
    raise Error, "Disk #{disk_target(disk)} has no source" if source.nil?

    case disk["type"]
    when "volume"
      pool = conn.lookup_storage_pool_by_name(source["pool"])
      pool.lookup_volume_by_name(source["volume"])
    when "file", "block"
      lookup_volume_by_path(source["file"] || source["dev"])
    else
      raise Error, "Disk #{disk_target(disk)} is a #{disk["type"]} disk; only disks in libvirt storage pools can be cloned"
    end
  rescue Libvirt::RetrieveError
    path = source && (source["file"] || source["dev"] || "#{source["pool"]}/#{source["volume"]}")
    raise Error, "Disk #{disk_target(disk)} (#{path}) is not in a libvirt storage pool. " \
                 "Define a pool for its directory on the KVM host, e.g.: virsh pool-define-as images dir --target /var/lib/libvirt/images && virsh pool-start images"
  end

  def lookup_volume_by_path(path)
    any_pool = conn.list_all_storage_pools.first
    raise Error, "The KVM host has no storage pools" if any_pool.nil?

    begin
      any_pool.lookup_volume_by_path(path)
    rescue Libvirt::RetrieveError
      # volume may exist but its pool was not refreshed yet
      conn.list_all_storage_pools.each { |p| p.refresh if p.active? rescue nil } # rubocop:disable Style/RescueModifier
      any_pool.lookup_volume_by_path(path)
    end
  end

  def destination_pool(name, src_vol)
    pool = name.present? ? conn.lookup_storage_pool_by_name(name) : src_vol.pool
    pool.create unless pool.active?
    pool
  rescue Libvirt::RetrieveError
    raise Error, "Storage pool [#{name}] was not found on the KVM host"
  end

  def pool_type(pool)
    Nokogiri::XML(pool.xml_desc).root["type"]
  end

  def volume_format(vol)
    Nokogiri::XML(vol.xml_desc).at_xpath("/volume/target/format")&.[]("type")
  rescue Libvirt::Error
    nil
  end

  def volume_name(name, disk, idx, fmt, ptype)
    base = idx.zero? ? name : "#{name}-#{disk_target(disk)}"
    return base if BLOCK_POOL_TYPES.include?(ptype) # LVM etc.: no extension

    ext = fmt == "qcow2" ? "qcow2" : "img"
    "#{base}.#{ext}"
  end

  def volume_xml(name, capacity, fmt, ptype)
    format = BLOCK_POOL_TYPES.include?(ptype) ? "" : "<target><format type='#{xml_escape(fmt)}'/></target>"
    "<volume><name>#{xml_escape(name)}</name><capacity unit='bytes'>#{capacity.to_i}</capacity>#{format}</volume>"
  end

  def overlay_xml(name, capacity, backing_path, backing_fmt)
    <<~XML
      <volume>
        <name>#{xml_escape(name)}</name>
        <capacity unit='bytes'>#{capacity.to_i}</capacity>
        <target><format type='qcow2'/></target>
        <backingStore><path>#{xml_escape(backing_path)}</path><format type='#{xml_escape(backing_fmt)}'/></backingStore>
      </volume>
    XML
  end

  def point_disk_at(disk, vol, fmt, ptype, pool)
    disk.xpath("source|backingStore").each(&:remove)
    driver = disk.at_xpath("driver") || disk.prepend_child(Nokogiri::XML::Node.new("driver", disk.document))
    driver["name"] ||= "qemu"
    driver["type"] = fmt

    source = Nokogiri::XML::Node.new("source", disk.document)
    if FILE_POOL_TYPES.include?(ptype)
      disk["type"] = "file"
      source["file"] = vol.path
    elsif BLOCK_POOL_TYPES.include?(ptype)
      disk["type"] = "block"
      source["dev"] = vol.path
    else
      disk["type"] = "volume"
      source["pool"]   = pool.name
      source["volume"] = vol.name
    end
    driver.add_next_sibling(source)
  end

  def disk_target(disk)
    disk.at_xpath("target")&.[]("dev") || "disk"
  end

  # CD-ROMs that carried the source's own cloud-init seed would hand the clone
  # the old hostname/IP: drop them.
  def remove_old_seed_cdroms(doc)
    doc.xpath("/domain/devices/disk[@device='cdrom']").each do |cd|
      path = cd.at_xpath("source")&.then { |s| s["file"] || s["dev"] || s["volume"] }.to_s
      cd.remove if /cidata|cloud-?init|seed/i.match?(path)
    end
  end

  # --- CPU / memory -------------------------------------------------------------

  def configure_cpu(doc, opts)
    sockets = opts[:sockets].to_i
    cores   = opts[:cores].to_i
    vcpus   = opts[:vcpus].to_i
    vcpus   = sockets * [cores, 1].max if vcpus <= 0 && sockets.positive?
    return unless vcpus.positive?

    root = doc.root
    vcpu = root.at_xpath("vcpu") || root.add_child(Nokogiri::XML::Node.new("vcpu", doc))
    vcpu.content = vcpus.to_s
    vcpu.remove_attribute("current")
    root.xpath("vcpus").each(&:remove) # per-vCPU hotplug map of the source
    root.xpath("cputune/vcpupin|cputune/vcpusched").each do |pin|
      ids = pin["vcpu"] || pin["vcpus"]
      pin.remove if ids.to_s.scan(/\d+/).map(&:to_i).any? { |id| id >= vcpus }
    end

    topology = root.at_xpath("cpu/topology")
    return unless topology || (cores > 1)

    sockets = vcpus / [cores, 1].max if sockets <= 0
    cores   = vcpus / [sockets, 1].max if cores <= 0
    if sockets * cores != vcpus # e.g. 3 vCPUs with 2 cores/socket: fall back to N sockets x 1 core
      sockets = vcpus
      cores   = 1
    end

    cpu = root.at_xpath("cpu") || root.add_child(Nokogiri::XML::Node.new("cpu", doc))
    topology ||= cpu.add_child(Nokogiri::XML::Node.new("topology", doc))
    %w[clusters dies].each { |a| topology.remove_attribute(a) }
    topology["sockets"] = sockets.to_s
    topology["dies"]    = "1"
    topology["cores"]   = cores.to_s
    topology["threads"] = "1"
  end

  def configure_memory(doc, memory_mb)
    memory_mb = memory_mb.to_i
    return unless memory_mb.positive?

    kib  = memory_mb * 1024
    root = doc.root
    %w[memory currentMemory].each do |el|
      node = root.at_xpath(el) || (el == "memory" ? root.add_child(Nokogiri::XML::Node.new(el, doc)) : nil)
      next unless node

      node["unit"] = "KiB"
      node.content = kib.to_s
    end
    max = root.at_xpath("maxMemory")
    if max && max.text.to_i * unit_factor(max["unit"]) < kib
      max["unit"] = "KiB"
      max.content = kib.to_s
    end
    cells = root.xpath("cpu/numa/cell")
    if cells.size == 1
      cells.first["unit"]   = "KiB"
      cells.first["memory"] = kib.to_s
    end
  end

  def unit_factor(unit)
    case unit.to_s.downcase
    when "", "k", "kib" then 1
    when "b", "bytes" then 1.0 / 1024
    when "m", "mib" then 1024
    when "g", "gib" then 1024 * 1024
    end || 1
  end

  # --- network ----------------------------------------------------------------

  def configure_network(doc, opts)
    devices = doc.at_xpath("/domain/devices")
    ifaces  = devices.xpath("interface")
    network = opts[:network].to_h.symbolize_keys

    first = ifaces.first
    if first.nil? && network[:name].present?
      first = Nokogiri::XML::Node.new("interface", doc)
      model = Nokogiri::XML::Node.new("model", doc)
      model["type"] = "virtio"
      first.add_child(model)
      devices.add_child(first)
      ifaces = devices.xpath("interface")
    end

    if first && network[:name].present?
      type = network[:type].to_s == "bridge" ? "bridge" : "network"
      first["type"] = type
      first.xpath("source|virtualport").each(&:remove)
      source = Nokogiri::XML::Node.new("source", doc)
      source[type] = network[:name]
      first.prepend_child(source)
    end

    # New MACs for every NIC; the first one may come from the request.
    mac = nil
    ifaces.each_with_index do |iface, idx|
      iface.xpath("mac").each(&:remove)
      addr = idx.zero? && opts[:mac].present? ? opts[:mac].to_s.downcase : generate_mac
      raise Error, "MAC address #{addr} is already used by another VM on this host" if idx.zero? && opts[:mac].present? && used_macs.include?(addr)

      node = Nokogiri::XML::Node.new("mac", doc)
      node["address"] = addr
      iface.prepend_child(node)
      mac ||= addr
    end
    mac
  end

  def used_macs
    @used_macs ||= conn.list_all_domains.flat_map do |d|
      Nokogiri::XML(d.xml_desc).xpath("//devices/interface/mac/@address").map { |a| a.value.downcase }
    rescue Libvirt::Error
      []
    end.to_set
  end

  # --- cloud-init -------------------------------------------------------------

  def attach_cloud_init(doc, name, opts)
    iso  = ManageIQ::Providers::Kvm::InfraManager::CloudInitIso.new(opts[:cloud_init])
    data = iso.to_s

    root_vol = created_volumes.first
    pool     = root_vol ? root_vol.pool : destination_pool(opts[:dest_pool], nil)
    ptype    = pool_type(pool)
    vol_name = BLOCK_POOL_TYPES.include?(ptype) ? "#{name}-cidata" : "#{name}-cidata.iso"
    pool.lookup_volume_by_name(vol_name).delete if volume_exists?(pool, vol_name) # leftover of a failed run

    vol = pool.create_volume_xml(volume_xml(vol_name, data.bytesize, "raw", ptype))
    created_volumes << vol
    upload_volume(vol, data)
    log.info("KVM clone: uploaded cloud-init seed #{vol.path} (#{data.bytesize} bytes)")

    add_cdrom(doc, vol, ptype, pool)
  end

  def upload_volume(vol, data)
    stream = conn.stream
    vol.upload(stream, 0, data.bytesize)
    offset = 0
    stream.sendall do |_opaque, nbytes|
      chunk = data.byteslice(offset, nbytes) || "".b
      offset += chunk.bytesize
      [0, chunk]
    end
    stream.finish
  rescue Libvirt::Error
    stream&.abort rescue nil # rubocop:disable Style/RescueModifier
    raise
  end

  def add_cdrom(doc, vol, ptype, pool)
    devices = doc.at_xpath("/domain/devices")
    q35     = doc.at_xpath("/domain/os/type")&.[]("machine").to_s.include?("q35")
    bus     = q35 ? "sata" : "ide"
    prefix  = q35 ? "sd" : "hd"
    used    = devices.xpath("disk/target/@dev").map(&:value)
    dev     = ("a".."z").map { |l| "#{prefix}#{l}" }.detect { |d| used.exclude?(d) }
    raise Error, "No free #{bus} slot for the cloud-init CD-ROM" if dev.nil?

    cd = Nokogiri::XML::Node.new("disk", doc)
    cd["device"] = "cdrom"
    driver = Nokogiri::XML::Node.new("driver", doc)
    driver["name"] = "qemu"
    driver["type"] = "raw"
    cd.add_child(driver)
    source = Nokogiri::XML::Node.new("source", doc)
    if FILE_POOL_TYPES.include?(ptype)
      cd["type"] = "file"
      source["file"] = vol.path
    elsif BLOCK_POOL_TYPES.include?(ptype)
      cd["type"] = "block"
      source["dev"] = vol.path
    else
      cd["type"] = "volume"
      source["pool"]   = pool.name
      source["volume"] = vol.name
    end
    cd.add_child(source)
    target = Nokogiri::XML::Node.new("target", doc)
    target["dev"] = dev
    target["bus"] = bus
    cd.add_child(target)
    cd.add_child(Nokogiri::XML::Node.new("readonly", doc))

    last_disk = devices.xpath("disk").last
    last_disk ? last_disk.add_next_sibling(cd) : devices.prepend_child(cd)
  end

  # --- helpers ----------------------------------------------------------------

  def domain_exists?(name)
    conn.lookup_domain_by_name(name)
    true
  rescue Libvirt::RetrieveError
    false
  end

  def volume_exists?(pool, name)
    pool.lookup_volume_by_name(name)
    true
  rescue Libvirt::RetrieveError
    false
  end

  def set_child_text(root, name, text, first: false, after: nil)
    node = root.at_xpath(name)
    unless node
      node = Nokogiri::XML::Node.new(name, root.document)
      anchor = after && root.at_xpath(after)
      if anchor
        anchor.add_next_sibling(node)
      elsif first
        root.prepend_child(node)
      else
        root.add_child(node)
      end
    end
    node.content = text
    node
  end

  def xml_escape(str)
    str.to_s.encode(:xml => :attr)[1..-2]
  end
end

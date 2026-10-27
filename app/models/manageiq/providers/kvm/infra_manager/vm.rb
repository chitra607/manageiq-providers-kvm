class ManageIQ::Providers::Kvm::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  include RemoteConsole
  include Disk
  include Snapshot
  include Migration
  include ManageIQ::Providers::Kvm::InfraManager::RemoveFromDisk

  extend Disk

  require 'net/ssh'
  require 'cgi'

  supports :capture
  supports :start
  supports :stop
  supports :pause
  supports :suspend
  supports :reset
  supports :reboot_guest

  supports :snapshots

  supports :console
  supports :vnc_console
  supports :clone do
    _('Clone operation is not supported') if blank? || orphaned? || archived?
  end
  # Lifecycle > Publish this VM to a Template (copies the VM into a template domain)
  supports :publish do
    _('Publish operation is not supported') if blank? || orphaned? || archived?
  end
  supports :migrate do
    _("No EMS is attached") unless ext_management_system
  end

  # Map libvirt raw_power_state strings â†’ ManageIQ power states
  POWER_STATES = {
    "on"        => "on",
    "off"       => "off",
    "paused"    => "paused",
    "suspended" => "suspended",
    "unknown"   => "unknown",
  }.freeze

  def self.calculate_power_state(raw_power_state)
    POWER_STATES[raw_power_state.to_s] || "unknown"
  end

  def metrics_capture_class
    ManageIQ::Providers::Kvm::InfraManager::MetricsCapture
  end

  def provider_object(connection = nil)
    connection ||= ext_management_system.connect
    connection.lookup_domain_by_uuid(ems_ref)
  rescue Libvirt::RetrieveError
    raise MiqException::MiqVmError, _("VM %{name} (%{uuid}) was not found on the KVM host") % {:name => name, :uuid => ems_ref}
  end

  def raw_start
    with_provider_object(&:create) # libvirt: create = boot a shutoff domain
    update!(:raw_power_state => "on")
  end

  def raw_stop
    with_provider_object(&:destroy) # force off
    update!(:raw_power_state => "off")
  end

  def raw_pause
    with_provider_object(&:suspend) # libvirt: suspend = pause
    update!(:raw_power_state => "paused")
  end

  def raw_resume
    with_provider_object(&:resume)
    update!(:raw_power_state => "on")
  end

  def raw_suspend
    with_provider_object(&:managed_save)
    update!(:raw_power_state => "suspended")
  end

  def raw_reset
    with_provider_object(&:reset)
    update!(:raw_power_state => "on")
  end

  def raw_reboot_guest
    with_provider_object(&:reboot)
    update!(:raw_power_state => "on")
  end

  def raw_shutdown_guest
    with_provider_object(&:shutdown)
    update!(:raw_power_state => "off")
  end

  def html5_console_redirect_info(_type, _user)
    ticket = get_console_info
    raise "No console available" if ticket.nil?

    {
      :proto    => "vnc",
      :host     => ticket[:host],
      :port     => ticket[:port],
      :password => nil
    }
  end

  def self.volumes(ems, data)
    ManageIQ::Providers::Kvm::InfraManager::Storage.volumes(ems, data)
  end

  def self.sources(ems, pool_name = "default")
    ems.with_provider_connection do |conn|
      pool = conn.lookup_storage_pool_by_name(pool_name)
      pool.list_all_volumes.map { |vol| {:id => vol.name, :name => vol.path} }
    end
  rescue Libvirt::Error
    []
  end

  def self.operating_systems(ems)
    require 'net/ssh'
    output = ""
    Net::SSH.start(
      ems.hostname,
      ems.authentication_userid,
      :password        => ems.authentication_password,
      :port            => (ems.port.presence || ManageIQ::Providers::Kvm::InfraManager::DEFAULT_SSH_PORT).to_i,
      :non_interactive => true,
      :timeout         => 15
    ) do |ssh|
      output = ssh.exec!("osinfo-query os").to_s
    end

    output.split("\n").drop(2).filter_map do |line|
      cols = line.split("|").map(&:strip)
      next if cols[0].blank?

      {:id => cols[0], :name => cols[1]}
    end
  end

  def self.raw_create_kvm_vm(ems, data)
    conn = ems.connect
    xml = build_vm_xml(data)
    conn.create_domain_xml(xml)
  end

  def self.build_vm_xml(data)
    name   = data["name"]
    memory = data["memory"].to_i * 1024
    disk   = data["installation_source"]["label"]
    type   = data["installation_type"]["value"]

    raise "Only cloud supported now" unless type == "cloud"

    <<-XML
    <domain type='kvm'>
      <name>#{name}</name>

      <memory unit='KiB'>#{memory}</memory>
      <currentMemory unit='KiB'>#{memory}</currentMemory>

      <vcpu>2</vcpu>

      <os>
        <type arch='x86_64'>hvm</type>
        <boot dev='hd'/>
      </os>

      <features>
        <acpi/>
        <apic/>
      </features>

      <cpu mode='host-model'/>

      <devices>

        <!-- Disk -->
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2'/>
          <source file='#{disk}'/>
          <target dev='vda' bus='virtio'/>
        </disk>

        <!-- Network -->
        <interface type='network'>
          <source network='default'/>
          <model type='virtio'/>
        </interface>

        <!-- Console -->
        <console type='pty'/>

        <!-- Graphics -->
        <graphics type='vnc' port='-1'/>

      </devices>
    </domain>
    XML
  end
end

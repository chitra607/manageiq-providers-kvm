module ManageIQ::Providers::Kvm::InfraManager::Provision::Cloning
  UUID_REGEX = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  # libvirt domain names: anything but "/" works, but keep them shell- and
  # file-name friendly because the disk files are named after the VM.
  VALID_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z/

  def find_destination_in_vmdb(ems_ref)
    return nil if ems_ref.blank?

    scope = create_template? ? ems.miq_templates : ems.vms
    scope.find_by(:ems_ref => ems_ref)
  end

  # Plain, non-secret options; stored in phase_context until the clone runs.
  def prepare_for_clone_task
    raise MiqException::MiqProvisionError, _("Destination name cannot be blank") if dest_name.blank?
    unless dest_name.match?(VALID_NAME)
      raise MiqException::MiqProvisionError,
            _("Destination name [%{name}] may only contain letters, digits, '.', '_' and '-' (max 63 characters)") % {:name => dest_name}
    end
    if ems.vms_and_templates.exists?(:name => dest_name)
      raise MiqException::MiqProvisionError, _("A VM or template named [%{name}] already exists") % {:name => dest_name}
    end

    {
      :source_uuid     => domain_source? ? source.ems_ref : nil,
      :source_volume   => domain_source? ? nil : source.location,
      :name            => dest_name,
      # Automate PreProvision writes owner / source template into :vm_notes
      :description     => get_option(:vm_notes).presence || get_option(:vm_description).presence,
      :dest_pool       => dest_datastore&.name,
      :linked          => linked_clone?,
      :disk_format     => requested_disk_format,
      :root_disk_size  => requested_root_disk_size,
      :sockets         => get_option(:number_of_sockets).to_i.nonzero?,
      :cores           => get_option(:cores_per_socket).to_i.nonzero?,
      :vcpus           => get_option(:number_of_cpus).to_i.nonzero?,
      :memory_mb       => get_option(:vm_memory).to_i.nonzero?,
      :network         => requested_network,
      :mac             => requested_mac,
      :template        => create_template?,
      :require_shutoff => !source.template?
    }
  end

  def log_clone_options(clone_options)
    _log.info("Provisioning [#{source.name}] to [#{dest_name}] (#{request_type})")
    _log.info("Source:          [#{source.name}] #{clone_options[:source_uuid] || clone_options[:source_volume]}")
    _log.info("Clone type:      [#{clone_options[:linked] ? "linked" : "full"}]")
    _log.info("Storage pool:    [#{clone_options[:dest_pool] || "same as source"}]")
    _log.info("CPU / memory:    [#{clone_options[:vcpus] || "#{clone_options[:sockets]}x#{clone_options[:cores]}"}] / [#{clone_options[:memory_mb]} MB]")
    _log.info("Root disk size:  [#{clone_options[:root_disk_size] || "as source"}]")
    _log.info("Network:         [#{clone_options[:network].inspect}]")
    dump_obj(options, "#{_log.prefix} Prov Options:  ", _log, :info, :protected => {:path => workflow_class.encrypted_options_field_regs})
  end

  # Runs the libvirt clone (synchronous; full copies can take a while).
  # Returns the DomainCloner result hash.
  def start_clone(clone_options)
    ems.with_provider_connection do |conn|
      cloner = ManageIQ::Providers::Kvm::InfraManager::DomainCloner.new(conn, _log)
      check_source_shut_off!(conn) if clone_options[:require_shutoff]

      opts = clone_options.except(:require_shutoff)
      opts[:mac] ||= cloner.generate_mac if customize_with_cloud_init?
      opts[:cloud_init] = cloud_init_payload(opts[:mac]) if customize_with_cloud_init?

      cloner.clone(opts)
    rescue ManageIQ::Providers::Kvm::InfraManager::DomainCloner::Error => err
      raise MiqException::MiqProvisionError, err.message
    rescue Libvirt::Error => err
      raise MiqException::MiqProvisionError, _("KVM clone failed: %{msg}") % {:msg => err.message}
    end
  end

  def linked_clone?
    source.template? && !create_template? && ActiveModel::Type::Boolean.new.cast(get_option(:linked_clone)) ? true : false
  end

  private

  # Template = libvirt domain (uuid ems_ref) or a bare disk image (volume key)
  def domain_source?
    source.ems_ref.to_s.match?(UUID_REGEX)
  end

  def check_source_shut_off!(conn)
    domain = conn.lookup_domain_by_uuid(source.ems_ref)
    return unless domain.active?

    raise MiqException::MiqProvisionError,
          _("VM [%{name}] is running. Shut it down before cloning or publishing it, so its disks are consistent.") % {:name => source.name}
  rescue Libvirt::RetrieveError
    raise MiqException::MiqProvisionError, _("Source VM [%{name}] was not found on the KVM host") % {:name => source.name}
  end

  # A fixed MAC only makes sense for one VM; with Count > 1 every VM gets a generated one.
  def requested_mac
    mac = get_option(:mac_address).to_s.strip.downcase.presence
    return nil if mac.nil?

    if get_option(:number_of_vms).to_i > 1
      _log.warn("Ignoring MAC address #{mac}: the request creates #{get_option(:number_of_vms)} VMs")
      return nil
    end
    mac
  end

  def requested_disk_format
    fmt = get_option(:disk_format).to_s
    %w[qcow2 raw].include?(fmt) ? fmt : nil
  end

  # :allocated_disk_storage is GB in the dialog
  def requested_root_disk_size
    gb = get_option(:allocated_disk_storage).to_f
    gb.positive? ? (gb * 1.gigabyte).to_i : nil
  end

  # :vlan holds the Lan name. Host bridges have uid_ems "bridge:<name>".
  def requested_network
    name = get_option(:vlan).to_s.sub(/\A(dvs_|bridge:)/, "")
    return nil if name.blank?

    lan = ems.lans.find_by(:name => name)
    type = lan&.uid_ems.to_s.start_with?("bridge:") ? "bridge" : "network"
    {:type => type, :name => name}
  end
end

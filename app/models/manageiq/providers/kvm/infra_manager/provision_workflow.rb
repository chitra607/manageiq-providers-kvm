class ManageIQ::Providers::Kvm::InfraManager::ProvisionWorkflow < ManageIQ::Providers::InfraManager::ProvisionWorkflow
  include CloudInitTemplateMixin

  DIALOG_PREFIX = "miq_provision_kvm_dialogs".freeze

  def self.provider_model
    ManageIQ::Providers::Kvm::InfraManager
  end

  def self.default_dialog_file
    "#{DIALOG_PREFIX}_template"
  end

  def dialog_name_from_automate(message = "get_dialog_name", extra_attrs = {})
    name = super(message, extra_attrs.reverse_merge("platform" => "kvm"))
    return name unless message == "get_dialog_name"
    return name if name.present? && MiqDialog.exists?(:name => name, :dialog_type => "MiqProvisionWorkflow")

    fallback = "#{DIALOG_PREFIX}_#{request_type}"
    MiqDialog.exists?(:name => fallback, :dialog_type => "MiqProvisionWorkflow") ? fallback : self.class.default_dialog_file
  end

  def supports_cloud_init?
    true
  end

  def allowed_provision_types(_options = {})
    {"native_clone" => _("Native Clone")}
  end

  def allowed_customization(_options = {})
    return {} if get_source_and_targets.blank?

    {"disabled" => _("<None>"), "fields" => _("Specification")}
  end

  def allowed_customization_templates(options = {})
    allowed_cloud_init_customization_templates(options)
  end

  def update_field_visibility(options = {})
    super(options.merge(:force_platform => "linux"))

    # core only shows Linked Clone for VMware
    show_fields(request_type == :template ? :edit : :hide, [:linked_clone])
  end

  # Core hides the Customize tab when the template's OS is not known; KVM
  # templates often have no guest agent data, so keep it for every source.
  def set_on_vm_id_changed
    super
    show_dialog(:customize, :show, "enabled") unless request_type == :clone_to_template
  end

  # rubocop:disable-next Naming/AccessorMethodName
  def set_or_default_hardware_field_values(vm)
    hw = vm.hardware
    if hw
      add_field_value(:vm_memory, hw.memory_mb.to_i.to_s) if hw.memory_mb.to_i.positive?
      add_field_value(:number_of_sockets, hw.cpu_sockets.to_i) if hw.cpu_sockets.to_i.positive?
      add_field_value(:cores_per_socket, hw.cpu_cores_per_socket.to_i) if hw.cpu_cores_per_socket.to_i.positive?
    end
    super
  end

  # --- placement ---------------------------------------------------------------

  # KVM inventory has no folder/cluster tree, so list the provider's hosts directly.
  def allowed_hosts_obj(_options = {})
    return [] if (src = resources_for_ui).blank? || src[:ems].nil?

    ems = load_ar_obj(src[:ems])
    process_filter(:host_filter, Host, ems.hosts).to_a
  end

  def allowed_hosts(_options = {})
    allowed_hosts_obj.collect { |h| ci_to_hash_struct(h) }
  end

  # Every storage pool of the provider; for a linked clone only the template's pool.
  def allowed_storages(_options = {})
    return [] if (src = resources_for_ui).blank? || src[:ems].nil?

    storages = load_ar_obj(src[:ems]).storages
    if get_value(@values[:linked_clone]) && (vm = load_ar_obj(src[:vm]))&.storage_id
      storages = storages.where(:id => vm.storage_id)
    end

    process_filter(:ds_filter, Storage, storages).collect { |s| ci_to_hash_struct(s) }
  end

  # libvirt networks and host bridges of the provider (core only lists
  # non-shared host switches).
  def load_allowed_vlans(_hosts, vlans)
    src = get_source_and_targets
    return vlans if src.blank? || src[:ems].nil?

    load_ar_obj(src[:ems]).lans.pluck(:name).compact.uniq.sort.each { |name| vlans[name] = name }
    vlans
  end

  # --- validation ----------------------------------------------------------------

  def validate_mac_address(field, values, dlg, fld, _value)
    mac = get_value(values[field]).to_s.strip
    return nil if mac.blank?
    return _("%{description} must look like 52:54:00:12:34:56") % {:description => required_description(dlg, fld)} unless mac.match?(/\A\h\h(:\h\h){5}\z/)
    return _("%{description} can only be set when provisioning one VM") % {:description => required_description(dlg, fld)} if get_value(values[:number_of_vms]).to_i > 1

    nil
  end

  def validate_vm_name(field, values, dlg, fld, value)
    error = super
    return error if error.present?

    # "$n{3}" (VM count numbering) is replaced per VM later; check the rest
    name = get_value(values[field]).to_s.gsub(/\$n\{\d+\}|\$n/, "001")
    return nil if name.blank? || name.match?(ManageIQ::Providers::Kvm::InfraManager::Provision::Cloning::VALID_NAME)

    _("%{description} may only contain letters, digits, '.', '_' and '-' and must start with a letter or digit") %
      {:description => required_description(dlg, fld)}
  end

  private

  def add_field_value(field_name, value)
    fields do |fn, f, _dn, _d|
      next unless fn == field_name && f[:values].kind_of?(Hash) && !f[:values].key?(value)

      f[:values] = f[:values].merge(value => value.to_s).sort_by { |k, _| k.to_i }.to_h
    end
  end
end

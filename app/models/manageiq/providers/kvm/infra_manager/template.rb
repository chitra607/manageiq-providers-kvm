class ManageIQ::Providers::Kvm::InfraManager::Template < ManageIQ::Providers::InfraManager::Template
  include ManageIQ::Providers::Kvm::InfraManager::RemoveFromDisk

  supports :provisioning do
    _("Provisioning is not supported for this template") if storage.nil?
  end

  def raw_destroy
    return super if ems_ref.to_s.match?(ManageIQ::Providers::Kvm::InfraManager::Provision::Cloning::UUID_REGEX)

    raise MiqException::MiqVmError, _("%{name} is a disk image template; delete the volume on the KVM host") % {:name => name}
  end
end

module ManageIQ::Providers::Kvm::InfraManager::RemoveFromDisk
  extend ActiveSupport::Concern

  included do
    supports :terminate do
      _("The VM is not connected to an active Provider") unless ext_management_system
    end
  end

  def raw_destroy
    raise MiqException::MiqVmError, unsupported_reason(:terminate) unless supports?(:terminate)

    ext_management_system.with_provider_connection do |conn|
      ManageIQ::Providers::Kvm::InfraManager::DomainCloner.destroy_domain(conn, ems_ref, _log)
    end
    EmsRefresh.queue_refresh(ext_management_system)
  rescue ManageIQ::Providers::Kvm::InfraManager::DomainCloner::Error => err
    raise MiqException::MiqVmError, err.message
  rescue Libvirt::RetrieveError
    # already gone on the host: let the refresh archive it
    EmsRefresh.queue_refresh(ext_management_system)
  end
end

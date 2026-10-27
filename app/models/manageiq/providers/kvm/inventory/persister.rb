class ManageIQ::Providers::Kvm::Inventory::Persister < ManageIQ::Providers::Inventory::Persister
  def initialize_inventory_collections
    # Hosts (the KVM hypervisor)
    add_collection(infra, :hosts)
    add_collection(infra, :host_hardwares)
    add_collection(infra, :host_operating_systems)
    add_collection(infra, :host_storages)
    add_collection(infra, :host_switches)

    add_collection(infra, :host_virtual_switches) do |builder|
      builder.add_properties(:model_class => ManageIQ::Providers::Kvm::InfraManager::Switch)
    end
    add_collection(infra, :host_virtual_lans)

    # Storage pools → Storage, volumes → StorageFile
    add_collection(infra, :storages)
    add_collection(infra, :storage_files) do |builder|
      # The EMS has no storage_files association, so tell the collection how
      # to find this provider's existing rows (needed to update/delete them).
      builder.add_properties(
        :model_class => ::StorageFile,
        :manager_ref => %i[storage name],
        :arel        => ::StorageFile.where(:storage_id => manager.storages.select(:id))
      )
    end

    # VMs
    add_collection(infra, :vms)
    add_collection(infra, :miq_templates) if discover_templates?
    add_collection(infra, :hardwares)
    add_collection(infra, :operating_systems)
    add_collection(infra, :disks)
    add_collection(infra, :guest_devices)
    add_collection(infra, :networks)
    add_collection(infra, :snapshots)
  end

  def discover_templates?
    ::Settings.ems_refresh.try(:kvm).try(:discover_templates) ? true : false
  end
end

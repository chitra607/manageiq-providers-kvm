# Where the new VM goes: the KVM host (one per provider) and the storage pool
# for its disks.
module ManageIQ::Providers::Kvm::InfraManager::Provision::Placement
  protected

  def placement
    host    = selected_placement_host || ems.hosts.first
    storage = selected_placement_storage
    storage ||= if linked_clone?
                  source.storage
                else
                  (placement_auto ? automatic_storage : nil) || source.storage
                end

    raise MiqException::MiqProvisionError, _("No KVM host found for provider %{name}") % {:name => ems.name} if host.nil?
    if linked_clone? && storage && source.storage && storage.id != source.storage.id
      raise MiqException::MiqProvisionError,
            _("A linked clone must be in the same storage pool as the template (%{pool})") % {:pool => source.storage.name}
    end

    options[:dest_host] = [host.id, host.name]
    _log.info("Using Host Id: [#{host.id}], Name: [#{host.name}]")
    if storage
      options[:dest_storage] = [storage.id, storage.name]
      _log.info("Using Storage pool Id: [#{storage.id}], Name: [#{storage.name}]")
    end
  end

  private

  def selected_placement_host
    id = get_option(:placement_host_name)
    id.present? ? ems.hosts.find_by(:id => id) : nil
  end

  def selected_placement_storage
    id = get_option(:placement_ds_name)
    id.present? ? ems.storages.find_by(:id => id) : nil
  end

  # Source pool if the copy fits there, otherwise the pool with most free space
  def automatic_storage
    needed = requested_root_disk_size.to_i.nonzero? || source.hardware&.disk_capacity.to_i
    src    = source.storage
    return src if src && src.free_space.to_i >= needed

    ems.storages.select { |s| s.free_space.to_i >= needed }.max_by { |s| s.free_space.to_i } || src
  end
end

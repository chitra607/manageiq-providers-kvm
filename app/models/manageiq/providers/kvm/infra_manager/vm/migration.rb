module ManageIQ::Providers::Kvm::InfraManager::Vm::Migration
  extend ActiveSupport::Concern

  MIGRATE_LIVE            = 1
  MIGRATE_PERSIST_DEST    = 8
  MIGRATE_UNDEFINE_SOURCE = 16
  MIGRATE_FLAGS_DEFAULT   = MIGRATE_LIVE | MIGRATE_PERSIST_DEST | MIGRATE_UNDEFINE_SOURCE

  def raw_migrate(dest, _pool = nil, _priority = nil, _state = nil, options: {})
    dest_ems = migration_target_ems(dest)
    raise MiqException::MiqVmMigrateError, _("Destination is the same KVM host") if dest_ems.id == ems_id

    flags = options[:flags] || MIGRATE_FLAGS_DEFAULT
    _log.info("KVM migrate: #{name} -> #{dest_ems.name} (flags=#{flags})")

    with_provider_object do |domain|
      dest_ems.with_provider_connection do |dest_conn|
        domain.migrate(dest_conn, flags, nil, nil, 0)
      end
    end

    EmsRefresh.queue_refresh(ext_management_system)
    EmsRefresh.queue_refresh(dest_ems)
  rescue Libvirt::Error => err
    raise MiqException::MiqVmMigrateError, _("KVM live migration failed: %{msg}") % {:msg => err.message}
  end

  private

  def migration_target_ems(dest)
    ems = case dest
          when ::Host
            dest.ext_management_system
          when ExtManagementSystem
            dest
          else
            ManageIQ::Providers::Kvm::InfraManager.find_by(:id => dest.to_s.to_i)
          end
    raise MiqException::MiqVmMigrateError, _("Destination KVM provider not found") unless ems.kind_of?(ManageIQ::Providers::Kvm::InfraManager)

    ems
  end
end

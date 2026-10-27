module ManageIQ::Providers::Kvm::InfraManager::Vm::Snapshot
  extend ActiveSupport::Concern

  require 'cgi'

  def snapshotting_memory_allowed?
    current_state == 'on'
  end

  def params_for_create_snapshot
    {
      :fields => [
        {
          :component  => 'text-field',
          :name       => 'name',
          :id         => 'name',
          :label      => _('Name'),
          :isRequired => true,
          :validate   => [{:type => 'required'}],
        },
        {
          :component => 'textarea',
          :name      => 'description',
          :id        => 'description',
          :label     => _('Description'),
        },
        {
          :component  => 'switch',
          :name       => 'memory',
          :id         => 'memory',
          :label      => _('Snapshot VM memory'),
          :onText     => _('Yes'),
          :offText    => _('No'),
          :isDisabled => current_state != 'on',
          :helperText => _('Snapshotting the memory is only available if the VM is powered on.'),
        },
      ],
    }
  end

  def raw_create_snapshot(name, desc = nil, _memory: false)
    with_provider_object do |domain|
      snapshot_xml = <<~XML
        <domainsnapshot>
          <name>#{CGI.escapeHTML(name.to_s)}</name>
          <description>#{CGI.escapeHTML(desc.to_s)}</description>
        </domainsnapshot>
      XML

      domain.snapshot_create_xml(snapshot_xml, 0)
    end
    refresh_ems
  rescue Libvirt::Error, MiqException::MiqVmError => err
    raise MiqException::MiqVmSnapshotError, err.message
  end

  def raw_remove_snapshot(snapshot_id)
    raise MiqException::MiqVmError, unsupported_reason(:remove_snapshot) unless supports?(:remove_snapshot)

    snapshot = snapshots.find_by(:id => snapshot_id)
    raise _('Requested VM snapshot not found, unable to remove snapshot') unless snapshot

    with_provider_object do |domain|
      domain.lookup_snapshot_by_name(snapshot.uid.presence || snapshot.name, 0).delete(0)
    end
    refresh_ems
  rescue Libvirt::Error => err
    raise MiqException::MiqVmSnapshotError, err.message
  end

  def raw_remove_all_snapshots
    raise MiqException::MiqVmError, unsupported_reason(:remove_all_snapshots) unless supports?(:remove_all_snapshots)

    snapshots.each { |snapshot| raw_remove_snapshot(snapshot.id) }
  end

  def raw_revert_to_snapshot(snapshot_id)
    raise MiqException::MiqVmError, unsupported_reason(:revert_to_snapshot) unless supports?(:revert_to_snapshot)

    snapshot = snapshots.find_by(:id => snapshot_id)
    raise _('Requested VM snapshot not found, unable to revert to snapshot') unless snapshot

    with_provider_object do |domain|
      libvirt_snapshot = domain.lookup_snapshot_by_name(snapshot.uid.presence || snapshot.name, 0)
      domain.revert_to_snapshot(libvirt_snapshot, 0)
    end
    refresh_ems
  rescue Libvirt::Error => err
    raise MiqException::MiqVmSnapshotError, err.message
  end
end

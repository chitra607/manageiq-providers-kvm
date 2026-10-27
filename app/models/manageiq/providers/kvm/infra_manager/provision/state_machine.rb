module ManageIQ::Providers::Kvm::InfraManager::Provision::StateMachine
  # Refresh the provider again if the new VM has not shown up after this many polls
  REFRESH_EVERY_POLLS = 12 # x 10 s
  MAX_VMDB_POLLS      = 60 # 10 minutes

  def create_destination
    signal :determine_placement
  end

  def determine_placement
    placement
    signal :prepare_provision
  end

  # Core prepare_provision, but the clone itself is queued with a long
  # timeout: a full copy of a big disk takes longer than the default 10 minutes.
  def prepare_provision
    update_and_notify_parent(:message => "Preparing to Clone #{clone_direction}")
    phase_context[:clone_options] = prepare_for_clone_task.merge(get_option(:clone_options) || {})
    save!
    queue_long_phase(:start_clone_task)
  end

  def start_clone_task
    update_and_notify_parent(:message => "Starting Clone of #{clone_direction}")
    clone_options = phase_context.delete(:clone_options) || prepare_for_clone_task
    log_clone_options(clone_options)

    result = start_clone(clone_options)
    phase_context[:new_vm_ems_ref] = result[:uuid]
    phase_context[:new_vm_mac]     = result[:mac]
    phase_context[:new_volumes]    = result[:volumes]
    phase_context[:vmdb_polls]     = 0
    save!
    _log.info("Clone of #{clone_direction} complete: uuid [#{result[:uuid]}], disks #{result[:volumes].inspect}")

    EmsRefresh.queue_refresh(ems)
    signal :poll_destination_in_vmdb
  end

  def poll_destination_in_vmdb
    update_and_notify_parent(:message => "Validating New #{destination_type}")

    self.destination = find_destination_in_vmdb(phase_context[:new_vm_ems_ref])
    if destination
      phase_context.delete(:new_vm_ems_ref)
      phase_context.delete(:vmdb_polls)
      signal :customize_destination
    else
      polls = phase_context[:vmdb_polls] = phase_context[:vmdb_polls].to_i + 1
      if polls > MAX_VMDB_POLLS
        raise MiqException::MiqProvisionError,
              _("%{type} [%{name}] was created on the KVM host but did not appear after the provider refresh") %
              {:type => destination_type, :name => dest_name}
      end
      EmsRefresh.queue_refresh(ems) if (polls % REFRESH_EVERY_POLLS).zero?
      _log.info("#{destination_type} [#{dest_name}] (#{phase_context[:new_vm_ems_ref]}) not in VMDB yet, will retry")
      requeue_phase
    end
  end

  # CPU, memory, disks, NIC and cloud-init were applied to the domain XML
  # during the clone, so nothing is left to change here.
  def customize_destination
    update_and_notify_parent(:message => "Starting New #{destination_type} Customization")
    signal :post_provision
  end

  def autostart_destination
    return signal(:post_create_destination) if create_template?

    super
  end

  private

  def queue_long_phase(phase)
    MiqQueue.put(
      :class_name     => self.class.name,
      :instance_id    => id,
      :method_name    => "signal",
      :args           => [phase],
      :zone           => my_zone,
      :role           => my_role,
      :queue_name     => my_queue_name,
      :tracking_label => tracking_label_id,
      :msg_timeout    => self.class.clone_time_limit,
      :miq_callback   => {:class_name => self.class.name, :instance_id => id, :method_name => :execute_callback}
    )
  end
end

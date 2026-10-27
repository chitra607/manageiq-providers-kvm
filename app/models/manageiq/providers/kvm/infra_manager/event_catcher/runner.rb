class ManageIQ::Providers::Kvm::InfraManager::EventCatcher::Runner < ManageIQ::Providers::BaseManager::EventCatcher::Runner
  def stop_event_monitor
    event_monitor_handle.stop
  rescue => err
    _log.warn("#{log_prefix} Event monitor stop failed: #{err.message}")
  ensure
    @event_monitor_handle = nil
  end

  def monitor_events
    event_monitor_handle.start
    event_monitor_running
    event_monitor_handle.poll do |event|
      @queue.enq(event)
    end
  ensure
    stop_event_monitor
  end

  def queue_event(event)
    _log.info("#{log_prefix} Caught kvm event [#{event[:name]}] for VM [#{event[:vm_name]}]")
    event_hash = event_to_hash(event, @cfg[:ems_id])
    EmsEvent.add_queue('add', @cfg[:ems_id], event_hash)
  end

  private

  def event_to_hash(event, ems_id)
    {
      :event_type => "KVM#{event[:name]}",
      :source     => 'KVM',
      :timestamp  => event[:timestamp],
      :vm_ems_ref => event[:vm_ems_ref],
      :vm_name    => event[:vm_name],
      :full_data  => event,
      :ems_id     => ems_id
    }
  end

  def event_monitor_handle
    @event_monitor_handle ||= self.class.module_parent::Stream.new(
      @ems,
      :poll_sleep => worker_settings[:poll]
    )
  end
end

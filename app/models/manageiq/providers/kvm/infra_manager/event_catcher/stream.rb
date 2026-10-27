# Polls libvirt for domain state changes and turns them into ManageIQ events.
#
# Event names match config/settings.yml and EventCatcher::PROVIDER_EVENTS once
# the runner adds the "KVM" prefix (e.g. "VmPoweredOnEvent" -> "KVMVmPoweredOnEvent").
# The old names ("instance_power_on" -> "KVMinstance_power_on") matched no
# event group, so they never reached timelines, policies or alerts.
class ManageIQ::Providers::Kvm::InfraManager::EventCatcher::Stream
  class ProviderUnreachable < ManageIQ::Providers::BaseManager::EventCatcher::Runner::TemporaryFailure
  end

  # libvirt virDomainState
  RUNNING     = 1
  BLOCKED     = 2
  PAUSED      = 3
  SHUTDOWN    = 4
  SHUTOFF     = 5
  CRASHED     = 6
  PMSUSPENDED = 7

  def initialize(ems, options = {})
    @ems                = ems
    @stop_polling       = false
    @poll_sleep         = options[:poll_sleep] || 20.seconds
    @last_domain_states = nil
  end

  def start
    @stop_polling = false
  end

  def stop
    @stop_polling = true
  end

  def poll
    @ems.with_provider_connection do |connection|
      catch(:stop_polling) do
        loop do
          throw :stop_polling if @stop_polling

          collect_domain_events(connection).each do |event|
            throw :stop_polling if @stop_polling

            yield event
          end

          sleep @poll_sleep
        end
      end
    end
  rescue => err # connection lost, host down, credentials changed ... -> runner reconnects
    raise ProviderUnreachable, err.message
  end

  private

  def collect_domain_events(connection)
    current = connection.list_all_domains.each_with_object({}) do |domain, h|
      h[domain_key(domain)] = {:name => domain.name, :state => domain_state(domain)}
    rescue Libvirt::Error
      next # domain vanished between list and lookup
    end

    # First poll only records a baseline
    if @last_domain_states.nil?
      @last_domain_states = current
      return []
    end

    events = []

    current.each do |uuid, data|
      previous = @last_domain_states[uuid]

      # QEMU starts a guest with paused vCPUs and resumes it a moment later.
      # Do not report that transient pause as "suspended": keep the old state
      # so the next poll reports SHUTOFF -> RUNNING as a power-on.
      if data[:state] == PAUSED && [SHUTOFF, SHUTDOWN, CRASHED].include?(previous&.dig(:state))
        current[uuid] = previous
        next
      end

      if previous.nil?
        events << build_event(uuid, data, nil, "VmDiscoveredOffEvent") if data[:state] == SHUTOFF
        events << build_event(uuid, data, nil, "VmPoweredOnEvent") if data[:state] == RUNNING
        next
      end
      next if previous[:state] == data[:state]

      name = event_name_for(previous[:state], data[:state])
      events << build_event(uuid, data, previous[:state], name) if name
    end

    (@last_domain_states.keys - current.keys).each do |uuid|
      events << build_event(uuid, @last_domain_states[uuid], @last_domain_states[uuid][:state], "VmDestroyedEvent")
    end

    @last_domain_states = current
    events
  end

  def event_name_for(previous_state, state)
    case state
    when RUNNING, BLOCKED
      [PAUSED, PMSUSPENDED].include?(previous_state) ? "VmResumedEvent" : "VmPoweredOnEvent"
    when PAUSED, PMSUSPENDED then "VmSuspendedEvent"
    when SHUTDOWN            then "VmShutdownEvent"
    when SHUTOFF             then "VmPoweredOffEvent"
    when CRASHED             then "VmCrashedEvent"
    else                          "VmStateChangeEvent"
    end
  end

  def build_event(uuid, data, previous_state, name)
    now = Time.now.utc
    {
      :id         => "#{uuid}-#{name}-#{now.to_f}",
      :name       => name,
      :timestamp  => now,
      :vm_ems_ref => uuid,
      :vm_name    => data[:name],
      :state      => data[:state],
      :previous   => previous_state
    }
  end

  def domain_key(domain)
    domain.uuid.to_s.presence || domain.name
  end

  def domain_state(domain)
    domain.state.first.to_i
  end
end

class ManageIQ::Providers::Kvm::InfraManager::EventCatcher < ManageIQ::Providers::BaseManager::EventCatcher
  require_relative "event_catcher/runner"

  PROVIDER_EVENTS = {
    "KVMVmPoweredOnEvent"     => {:event_group => :vm_lifecycle,     :enabled => true},
    "KVMVmPoweredOffEvent"    => {:event_group => :vm_lifecycle,     :enabled => true},
    "KVMVmShutdownEvent"      => {:event_group => :vm_lifecycle,     :enabled => true},
    "KVMVmSuspendedEvent"     => {:event_group => :vm_lifecycle,     :enabled => true},
    "KVMVmResumedEvent"       => {:event_group => :vm_lifecycle,     :enabled => true},
    "KVMVmCrashedEvent"       => {:event_group => :vm_lifecycle,     :enabled => true},
    "KVMVmDestroyedEvent"     => {:event_group => :vm_lifecycle,     :enabled => true},
    "KVMVmDiscoveredOffEvent" => {:event_group => :vm_lifecycle,     :enabled => true},
    "KVMVmStateChangeEvent"   => {:event_group => :vm_configuration, :enabled => true},
  }.freeze

  def self.ems_class
    ManageIQ::Providers::Kvm::InfraManager
  end

  def self.settings_name
    :event_catcher_kvm
  end
end

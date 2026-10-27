class ManageIQ::Providers::Kvm::InfraManager::MetricsCollectorWorker < ManageIQ::Providers::BaseManager::MetricsCollectorWorker
  self.default_queue_name = "kvm"

  def friendly_name
    @friendly_name ||= "C&U Metrics Collector for Kvm"
  end

  def self.settings_name
    :ems_metrics_collector_worker_kvm
  end
end

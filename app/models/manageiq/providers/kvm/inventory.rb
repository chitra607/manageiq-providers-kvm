class ManageIQ::Providers::Kvm::Inventory < ManageIQ::Providers::Inventory
  def self.default_manager_name
    "InfraManager"
  end

  def parse
    super
  ensure
    collector.disconnect if collector.respond_to?(:disconnect)
  end
end

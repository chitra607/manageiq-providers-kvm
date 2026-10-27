class ManageIQ::Providers::Kvm::InfraManager::Provision < MiqProvision
  include Cloning
  include Configuration
  include Placement
  include StateMachine

  VALID_REQUEST_TYPES = %w[template clone_to_vm clone_to_template].freeze
  validates :request_type, :inclusion => {:in      => VALID_REQUEST_TYPES,
                                          :message => "should be one of: #{VALID_REQUEST_TYPES.join(', ')}"}

  DEFAULT_CLONE_TIME_LIMIT = 80.minutes

  def self.clone_time_limit
    value = ::Settings.ems.try(:ems_kvm).try(:provision_clone_timeout)
    value.present? ? value.to_s.to_i_with_method : DEFAULT_CLONE_TIME_LIMIT
  end

  def destination_type
    create_template? ? "Template" : "Vm"
  end

  def ems
    (destination || source)&.ext_management_system
  end
end

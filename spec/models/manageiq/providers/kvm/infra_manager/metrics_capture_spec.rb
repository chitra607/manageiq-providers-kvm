describe ManageIQ::Providers::Kvm::InfraManager::MetricsCapture do
  it 'uses the infra metrics capture implementation for automatic target discovery' do
    expect(described_class < ManageIQ::Providers::InfraManager::MetricsCapture).to(be(true))
    expect(described_class.instance_method(:capture_ems_targets).owner).to(eq(ManageIQ::Providers::InfraManager::MetricsCapture))
  end
end

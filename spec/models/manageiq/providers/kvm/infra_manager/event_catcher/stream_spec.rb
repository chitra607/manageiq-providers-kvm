require 'spec_helper'

RSpec.describe(ManageIQ::Providers::Kvm::InfraManager::EventCatcher::Stream) do
  subject(:stream) { described_class.new(ems, :poll_sleep => 0) }

  let(:ems) { instance_double(ManageIQ::Providers::Kvm::InfraManager) }

  def domain(state)
    instance_double('Libvirt::Domain', :name => 'vm-1', :uuid => 'uuid-1', :state => [state, 0])
  end

  describe '#collect_domain_events' do
    it 'records a baseline first, then reports power-state transitions with settings.yml event names' do
      connection = instance_double('Libvirt::Connect')
      allow(connection).to(receive(:list_all_domains).and_return([domain(5)], [domain(1)], [domain(3)], []))

      expect(stream.send(:collect_domain_events, connection)).to(eq([]))

      events = stream.send(:collect_domain_events, connection)
      expect(events.size).to(eq(1))
      expect(events.first).to(include(:name => 'VmPoweredOnEvent', :vm_ems_ref => 'uuid-1', :vm_name => 'vm-1'))

      expect(stream.send(:collect_domain_events, connection).first[:name]).to(eq('VmSuspendedEvent'))
      expect(stream.send(:collect_domain_events, connection).first[:name]).to(eq('VmDestroyedEvent'))
    end
  end
end

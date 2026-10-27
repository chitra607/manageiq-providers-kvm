require "spec_helper"

RSpec.describe(ManageIQ::Providers::Kvm::InfraManager::ProvisionWorkflow) do
  let(:workflow) { described_class.allocate }

  before { workflow.instance_variable_set(:@values, {}) }

  describe ".default_dialog_file" do
    it "is the KVM template dialog" do
      expect(described_class.default_dialog_file).to(eq("miq_provision_kvm_dialogs_template"))
    end
  end

  describe "#allowed_hosts" do
    let(:host) { double(:id => 1, :name => "kvm-host") }
    let(:ems)  { double(:hosts => [host]) }

    before do
      allow(workflow).to(receive(:resources_for_ui).and_return(:ems => 1))
      allow(workflow).to(receive(:load_ar_obj).with(1).and_return(ems))
      allow(workflow).to(receive(:process_filter).with(:host_filter, Host, [host]).and_return([host]))
      allow(workflow).to(receive(:ci_to_hash_struct).with(host).and_return(host))
    end

    it "lists the provider's hosts (KVM has no folder/cluster tree)" do
      expect(workflow.allowed_hosts).to(eq([host]))
    end
  end

  describe "#allowed_storages" do
    let(:storage) { double(:id => 1, :name => "default") }
    let(:ems)     { double(:storages => [storage]) }

    before do
      allow(workflow).to(receive(:resources_for_ui).and_return(:ems => 1))
      allow(workflow).to(receive(:load_ar_obj).with(1).and_return(ems))
      allow(workflow).to(receive(:process_filter).with(:ds_filter, Storage, [storage]).and_return([storage]))
      allow(workflow).to(receive(:ci_to_hash_struct).with(storage).and_return(storage))
    end

    it "lists every storage pool of the provider" do
      expect(workflow.allowed_storages).to(eq([storage]))
    end
  end

  describe "#load_allowed_vlans" do
    it "offers libvirt networks and host bridges by name" do
      lans = double
      allow(lans).to(receive(:pluck).with(:name).and_return(%w[default br0 default]))
      allow(workflow).to(receive(:get_source_and_targets).and_return(:ems => 1))
      allow(workflow).to(receive(:load_ar_obj).with(1).and_return(double(:lans => lans)))

      expect(workflow.load_allowed_vlans([], {})).to(eq("br0" => "br0", "default" => "default"))
    end
  end

  describe "#allowed_customization" do
    it "offers cloud-init specification" do
      allow(workflow).to(receive(:get_source_and_targets).and_return(:vm => double))
      expect(workflow.allowed_customization).to(eq("disabled" => "<None>", "fields" => "Specification"))
    end
  end
end

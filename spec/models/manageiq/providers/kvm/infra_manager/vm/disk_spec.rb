require "spec_helper"

RSpec.describe(ManageIQ::Providers::Kvm::InfraManager::Vm::Disk) do
  subject(:vm) { Class.new { include ManageIQ::Providers::Kvm::InfraManager::Vm::Disk }.new }

  describe "#next_disk_target (private)" do
    it "returns the first free vdX target" do
      domain = double("domain", :xml_desc => <<~XML)
        <domain><devices>
          <disk device='disk'><target dev='vda'/></disk>
          <disk device='disk'><target dev='vdb'/></disk>
        </devices></domain>
      XML

      expect(vm.send(:next_disk_target, domain)).to(eq("vdc"))
    end
  end

  describe "#build_disk_xml (private)" do
    it "builds a libvirt volume definition" do
      xml = vm.send(:build_disk_xml, "name" => "data.qcow2", "size" => 10, "format" => "qcow2")

      expect(xml).to(include("<name>data.qcow2</name>"))
      expect(xml).to(include('<capacity unit="G">10</capacity>'))
      expect(xml).to(include('<format type="qcow2"/>'))
    end
  end
end

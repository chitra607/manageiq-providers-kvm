require "manageiq/providers/kvm"

RSpec.describe(ManageIQ::Providers::Kvm::Engine) do
  describe ".seedable_classes" do
    it "does not declare non-seedable plugin classes" do
      expect(described_class.seedable_classes).to(eq([]))
    end
  end
end

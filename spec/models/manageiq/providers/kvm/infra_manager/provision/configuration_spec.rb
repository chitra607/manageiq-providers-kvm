require "spec_helper"

RSpec.describe(ManageIQ::Providers::Kvm::InfraManager::Provision::Configuration) do
  let(:mac) { "52:54:00:12:34:56" }
  let(:base_options) do
    {
      :sysprep_enabled => ["fields", "Specification"],
      :hostname        => "web01.example.com",
      :root_password   => "S3cret!",
      :dns_servers     => "10.0.0.2, 10.0.0.3",
      :dns_suffixes    => "example.com"
    }
  end
  let(:options) { base_options }

  let(:provision) do
    Class.new do
      include ManageIQ::Providers::Kvm::InfraManager::Provision::Configuration

      attr_reader :options

      def initialize(options)
        @options = options
      end

      def get_option(key)
        value = options[key]
        value.kind_of?(Array) ? value.first : value
      end

      def create_template?
        options[:request_type] == :clone_to_template
      end

      def dest_name
        "web01"
      end

      def dest_hostname
        "web01"
      end

      def id
        7
      end

      def customization_template
        nil
      end
    end.new(options)
  end

  let(:payload) { provision.cloud_init_payload(mac) }

  it "is used for 'Specification' and not when publishing a template" do
    expect(provision.customize_with_cloud_init?).to(be(true))
    options[:request_type] = :clone_to_template
    expect(provision.customize_with_cloud_init?).to(be(false))
  end

  it "builds meta-data with instance-id and host name" do
    meta = YAML.safe_load(payload["meta-data"])
    expect(meta).to(eq("instance-id" => "iid-web01-7", "local-hostname" => "web01.example.com"))
  end

  it "builds #cloud-config user-data with hostname, fqdn and root password" do
    expect(payload["user-data"]).to(start_with("#cloud-config\n"))
    data = YAML.safe_load(payload["user-data"])
    expect(data).to(include("hostname" => "web01", "fqdn" => "web01.example.com", "ssh_pwauth" => true))
    expect(data["chpasswd"]).to(eq("list" => "root:S3cret!", "expire" => false))
  end

  it "has no network-config for DHCP" do
    expect(payload).not_to(have_key("network-config"))
  end

  context "with a static address" do
    let(:options) do
      base_options.merge(:addr_mode => ["static", "Static"], :ip_addr => "10.0.0.21", :subnet_mask => "255.255.255.0", :gateway => "10.0.0.1")
    end

    it "writes network-config v2 for the NIC with the given MAC" do
      net = YAML.safe_load(payload["network-config"])
      eth = net.dig("ethernets", "eth0")

      expect(net["version"]).to(eq(2))
      expect(eth["match"]).to(eq("macaddress" => mac))
      expect(eth["addresses"]).to(eq(["10.0.0.21/24"]))
      expect(eth["routes"]).to(eq([{"to" => "0.0.0.0/0", "via" => "10.0.0.1"}]))
      expect(eth["nameservers"]).to(eq("addresses" => %w[10.0.0.2 10.0.0.3], "search" => ["example.com"]))
    end

    it "accepts a prefix length as subnet mask" do
      options[:subnet_mask] = "22"
      expect(YAML.safe_load(payload["network-config"]).dig("ethernets", "eth0", "addresses")).to(eq(["10.0.0.21/22"]))
    end

    it "requires a subnet mask" do
      options[:subnet_mask] = ""
      expect { payload }.to(raise_error(MiqException::MiqProvisionError, /Subnet Mask/))
    end
  end
end

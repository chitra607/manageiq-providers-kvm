require "spec_helper"

# Runs against libvirt's built-in test driver (no hypervisor needed).
RSpec.describe(ManageIQ::Providers::Kvm::InfraManager::DomainCloner) do
  let(:conn) { Libvirt.open("test:///default") }
  let(:pool) { conn.lookup_storage_pool_by_name("default-pool") }
  let!(:source_vol) do
    pool.create_volume_xml("<volume><name>tpl-#{SecureRandom.hex(4)}.qcow2</name><capacity unit='G'>1</capacity><target><format type='qcow2'/></target></volume>")
  end
  let!(:source) do
    conn.define_domain_xml(<<~XML)
      <domain type='test'>
        <name>tpl-#{SecureRandom.hex(4)}</name>
        <title>golden</title>
        <metadata><miq:template xmlns:miq="#{described_class::TEMPLATE_NS}"/></metadata>
        <memory unit='MiB'>512</memory>
        <vcpu current='1'>2</vcpu>
        <os><type>hvm</type></os>
        <devices>
          <disk type='file' device='disk'>
            <source file='#{source_vol.path}'/>
            <target dev='vda' bus='virtio'/>
            <serial>SRC</serial>
          </disk>
          <interface type='network'><mac address='52:54:00:00:00:01'/><source network='default'/></interface>
          <graphics type='vnc' port='5905' autoport='no'/>
        </devices>
      </domain>
    XML
  end

  after { conn.close }

  def xml_of(name)
    Nokogiri::XML(conn.lookup_domain_by_name(name).xml_desc)
  end

  it "detects the template flag" do
    expect(described_class.template_xml?(Nokogiri::XML(source.xml_desc))).to(be(true))
  end

  it "full-clones the disks and rewrites the domain for the new VM" do
    result = described_class.new(conn).clone(
      :source_uuid => source.uuid, :name => "web01", :description => "app server",
      :sockets => 2, :cores => 2, :memory_mb => 1024, :network => {:type => "bridge", :name => "br0"}
    )
    doc = xml_of("web01")

    expect(result[:uuid]).not_to(eq(source.uuid))
    expect(result[:volumes]).to(eq([File.join(File.dirname(source_vol.path), "web01.qcow2")]))
    expect(doc.at_xpath("//disk[@device='disk']/source")["file"]).to(eq(result[:volumes].first))
    expect(doc.at_xpath("//disk/serial")).to(be_nil)
    expect(doc.at_xpath("/domain/vcpu").text).to(eq("4"))
    expect(doc.at_xpath("//cpu/topology").attributes.transform_values(&:value)).to(include("sockets" => "2", "cores" => "2"))
    expect(doc.at_xpath("/domain/memory").text.to_i).to(eq(1024 * 1024))
    expect(doc.at_xpath("//interface")["type"]).to(eq("bridge"))
    expect(doc.at_xpath("//interface/source")["bridge"]).to(eq("br0"))
    expect(doc.at_xpath("//interface/mac")["address"]).to(eq(result[:mac]))
    expect(result[:mac]).not_to(eq("52:54:00:00:00:01"))
    expect(doc.at_xpath("/domain/title")).to(be_nil)
    expect(doc.at_xpath("/domain/description").text).to(eq("app server"))
    expect(doc.at_xpath("//graphics")["autoport"]).to(eq("yes"))
    expect(described_class.template_xml?(doc)).to(be(false))
  end

  it "creates a qcow2 overlay for a linked clone" do
    result = described_class.new(conn).clone(:source_uuid => source.uuid, :name => "web02", :linked => true)
    vol    = pool.lookup_volume_by_path(result[:volumes].first)

    expect(Nokogiri::XML(vol.xml_desc).at_xpath("//backingStore/path")&.text).to(eq(source_vol.path))
  end

  it "marks a published template" do
    described_class.new(conn).clone(:source_uuid => source.uuid, :name => "tpl-web", :template => true)
    expect(described_class.template_xml?(xml_of("tpl-web"))).to(be(true))
  end

  it "removes the volumes it created when defining the domain fails" do
    before = pool.list_volumes.sort
    expect do
      described_class.new(conn).clone(:source_uuid => source.uuid, :name => "bad01", :mac => "zz:zz")
    end.to(raise_error(Libvirt::DefinitionError))
    expect(pool.list_volumes.sort).to(eq(before))
  end

  it "refuses an existing name" do
    expect { described_class.new(conn).clone(:source_uuid => source.uuid, :name => source.name) }
      .to(raise_error(described_class::Error, /already exists/))
  end

  it "refuses to remove a template that a linked clone depends on, removes the clone with its disk" do
    clone = described_class.new(conn).clone(:source_uuid => source.uuid, :name => "lc01", :linked => true)

    expect { described_class.destroy_domain(conn, source.uuid) }.to(raise_error(described_class::Error, /lc01 is a linked clone/))

    described_class.destroy_domain(conn, clone[:uuid])
    expect { conn.lookup_domain_by_uuid(clone[:uuid]) }.to(raise_error(Libvirt::RetrieveError))
    expect { pool.lookup_volume_by_path(clone[:volumes].first) }.to(raise_error(Libvirt::RetrieveError))
  end
end

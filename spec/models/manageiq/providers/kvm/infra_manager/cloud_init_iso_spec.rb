require "spec_helper"

RSpec.describe(ManageIQ::Providers::Kvm::InfraManager::CloudInitIso) do
  let(:files) do
    {
      "user-data"      => "#cloud-config\nhostname: web01\n#{"x" * 3000}\n",
      "meta-data"      => "instance-id: iid-web01\n",
      "network-config" => "version: 2\n"
    }
  end
  let(:image) { described_class.new(files).to_s }

  def sector(number)
    image.byteslice(number * 2048, 2048)
  end

  # Joliet root directory: {name => [extent, size]}
  def joliet_entries
    svd    = sector(17)
    extent = svd.byteslice(156 + 2, 4).unpack1("V")
    dir    = sector(extent)
    pos    = 0
    result = {}
    while (len = dir.getbyte(pos)).to_i.positive?
      rec  = dir.byteslice(pos, len)
      nlen = rec.getbyte(32)
      name = rec.byteslice(33, nlen)
      result[name.dup.force_encoding("UTF-16BE").encode("UTF-8")] = [rec.byteslice(2, 4).unpack1("V"), rec.byteslice(10, 4).unpack1("V")] if nlen > 1
      pos += len
    end
    result
  end

  it "is a whole number of 2 KiB sectors" do
    expect(image.bytesize % 2048).to(eq(0))
  end

  it "has the 'cidata' volume label NoCloud looks for, in the primary and the Joliet descriptor" do
    expect(sector(16).byteslice(1, 5)).to(eq("CD001"))
    expect(sector(16).byteslice(40, 6)).to(eq("CIDATA"))
    expect(sector(17).getbyte(0)).to(eq(2))
    expect(sector(17).byteslice(88, 3)).to(eq("%/E"))
    expect(sector(17).byteslice(40, 12).force_encoding("UTF-16BE").encode("UTF-8")).to(eq("cidata"))
    expect(sector(18).getbyte(0)).to(eq(255))
  end

  it "keeps the lower-case cloud-init file names and contents in the Joliet tree" do
    entries = joliet_entries
    expect(entries.keys).to(match_array(%w[meta-data network-config user-data]))

    files.each do |name, content|
      extent, size = entries[name]
      expect(image.byteslice(extent * 2048, size)).to(eq(content.b))
    end
  end

  it "does not take a Hash with String keys for keyword arguments" do
    expect { described_class.new("user-data" => "a", "meta-data" => "b").to_s }.not_to(raise_error)
  end
end

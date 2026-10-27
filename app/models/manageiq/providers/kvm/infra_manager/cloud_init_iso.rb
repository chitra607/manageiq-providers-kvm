class ManageIQ::Providers::Kvm::InfraManager::CloudInitIso
  SECTOR       = 2048
  VOLUME_LABEL = "cidata".freeze

  # Sector layout
  PVD_SECTOR        = 16
  SVD_SECTOR        = 17
  TERMINATOR_SECTOR = 18
  L_PATH_SECTOR     = 19
  M_PATH_SECTOR     = 20
  JL_PATH_SECTOR    = 21
  JM_PATH_SECTOR    = 22
  ROOT_SECTOR       = 23
  JROOT_SECTOR      = 24
  FIRST_FILE_SECTOR = 25

  attr_reader :files

  # files: {"user-data" => String, "meta-data" => String, "network-config" => String}
  # (positional only: a Hash with String keys must not be taken for keywords)
  def initialize(files, label = VOLUME_LABEL, time = Time.now.utc)
    raise ArgumentError, "at least one file is required" if files.blank?

    @files = files.to_h.transform_keys(&:to_s).transform_values { |v| v.to_s.b }.sort.to_h
    @label = label
    @time  = time.utc
    raise ArgumentError, "too many files for one directory sector" if @files.size > 20
  end

  def to_s
    @to_s ||= build
  end

  def size
    to_s.bytesize
  end

  private

  def build
    layout = file_layout
    total_sectors = layout.values.map { |l| l[:sector] + l[:sectors] }.max || FIRST_FILE_SECTOR

    image = "\0".b * (total_sectors * SECTOR)
    put(image, PVD_SECTOR, volume_descriptor(:primary, total_sectors))
    put(image, SVD_SECTOR, volume_descriptor(:joliet, total_sectors))
    put(image, TERMINATOR_SECTOR, terminator)
    put(image, L_PATH_SECTOR, path_table(ROOT_SECTOR, :little))
    put(image, M_PATH_SECTOR, path_table(ROOT_SECTOR, :big))
    put(image, JL_PATH_SECTOR, path_table(JROOT_SECTOR, :little))
    put(image, JM_PATH_SECTOR, path_table(JROOT_SECTOR, :big))
    put(image, ROOT_SECTOR, directory(ROOT_SECTOR, layout, :primary))
    put(image, JROOT_SECTOR, directory(JROOT_SECTOR, layout, :joliet))
    layout.each { |name, l| put(image, l[:sector], @files[name]) }
    image
  end

  def file_layout
    sector = FIRST_FILE_SECTOR
    @files.each_with_object({}) do |(name, data), h|
      sectors = [(data.bytesize + SECTOR - 1) / SECTOR, 1].max
      h[name] = {:sector => sector, :sectors => sectors, :size => data.bytesize}
      sector += sectors
    end
  end

  def put(image, sector, data)
    image[sector * SECTOR, data.bytesize] = data
  end

  # --- descriptors -----------------------------------------------------------

  def volume_descriptor(kind, total_sectors)
    joliet = kind == :joliet
    vd = "\0".b * SECTOR
    vd[0] = [joliet ? 2 : 1].pack("C")
    vd[1, 5] = "CD001"
    vd[6] = "\x01".b
    vd[8, 32]  = text("LINUX", 32, joliet)
    vd[40, 32] = text(joliet ? @label : @label.upcase, 32, joliet)
    vd[80, 8]  = both32(total_sectors)
    vd[88, 3]  = "%/E" if joliet # UCS-2 level 3
    vd[120, 4] = both16(1)
    vd[124, 4] = both16(1)
    vd[128, 4] = both16(SECTOR)
    vd[132, 8] = both32(10) # path table size: one root entry
    vd[140, 4] = [joliet ? JL_PATH_SECTOR : L_PATH_SECTOR].pack("V")
    vd[148, 4] = [joliet ? JM_PATH_SECTOR : M_PATH_SECTOR].pack("N")
    vd[156, 34] = dir_record("\0".b, joliet ? JROOT_SECTOR : ROOT_SECTOR, SECTOR, true)
    vd[190, 128] = text("", 128, joliet)                # volume set
    vd[318, 128] = text("", 128, joliet)                # publisher
    vd[446, 128] = text("", 128, joliet)                # data preparer
    vd[574, 128] = text("MANAGEIQ KVM", 128, joliet)    # application
    vd[702, 37]  = text("", 37, joliet)
    vd[739, 37]  = text("", 37, joliet)
    vd[776, 37]  = text("", 37, joliet)
    vd[813, 17]  = long_date(@time)
    vd[830, 17]  = long_date(@time)
    vd[847, 17]  = "0000000000000000\0".b
    vd[864, 17]  = "0000000000000000\0".b
    vd[881] = "\x01".b
    vd
  end

  def terminator
    vd = "\0".b * SECTOR
    vd[0] = "\xFF".b
    vd[1, 5] = "CD001"
    vd[6] = "\x01".b
    vd
  end

  def path_table(root_sector, endian)
    loc = endian == :little ? [root_sector].pack("V") : [root_sector].pack("N")
    parent = endian == :little ? [1].pack("v") : [1].pack("n")
    ("\x01\x00".b + loc + parent + "\x00\x00".b).ljust(SECTOR, "\0")
  end

  def directory(self_sector, layout, kind)
    joliet  = kind == :joliet
    records = dir_record("\0".b, self_sector, SECTOR, true) +
              dir_record("\x01".b, self_sector, SECTOR, true)
    entries = layout.map { |name, l| [joliet ? joliet_name(name) : primary_name(name), l] }
    entries.sort_by(&:first).each { |id, l| records << dir_record(id, l[:sector], l[:size], false) }
    raise ArgumentError, "directory does not fit in one sector" if records.bytesize > SECTOR

    records.ljust(SECTOR, "\0")
  end

  def dir_record(identifier, sector, size, directory)
    id  = identifier.b
    len = 33 + id.bytesize
    len += 1 if len.odd?
    rec = "\0".b * len
    rec[0] = [len].pack("C")
    rec[2, 8]  = both32(sector)
    rec[10, 8] = both32(size)
    rec[18, 7] = short_date(@time)
    rec[25] = [directory ? 2 : 0].pack("C")
    rec[28, 4] = both16(1)
    rec[32] = [id.bytesize].pack("C")
    rec[33, id.bytesize] = id
    rec
  end

  # --- names / encodings -----------------------------------------------------

  # ISO 9660 level 1 (8.3, upper case, d-characters): "user-data" -> "USER_DAT.;1"
  def primary_name(name)
    base, ext = name.split(".", 2)
    clean = ->(s, n) { s.to_s.upcase.gsub(/[^A-Z0-9_]/, "_")[0, n] }
    "#{clean.call(base, 8)}.#{clean.call(ext, 3)};1".b
  end

  def joliet_name(name)
    name.encode("UTF-16BE").b
  end

  def text(str, len, joliet)
    if joliet
      encoded = str.to_s.encode("UTF-16BE").b[0, len - (len % 2)]
      encoded + ("\x00\x20".b * len)[0, len - encoded.bytesize] # UCS-2 spaces
    else
      str.to_s.upcase.b[0, len].ljust(len, " ")
    end
  end

  def both16(value)
    [value].pack("v") + [value].pack("n")
  end

  def both32(value)
    [value].pack("V") + [value].pack("N")
  end

  def short_date(time)
    [time.year - 1900, time.month, time.day, time.hour, time.min, time.sec, 0].pack("C6c")
  end

  def long_date(time)
    "#{time.strftime("%Y%m%d%H%M%S")}00".b + "\0".b
  end
end

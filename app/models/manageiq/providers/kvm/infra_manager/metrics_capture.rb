require "nokogiri"

class ManageIQ::Providers::Kvm::InfraManager::MetricsCapture < ManageIQ::Providers::InfraManager::MetricsCapture
  VIM_STYLE_COUNTERS = {
    "cpu_usage_rate_average"     => {
      :counter_key           => "cpu_usage_rate_average",
      :instance              => "",
      :capture_interval      => "20",
      :precision             => 1,
      :rollup                => "average",
      :unit_key              => "percent",
      :capture_interval_name => "realtime"
    },
    "disk_usage_rate_average"    => {
      :counter_key           => "disk_usage_rate_average",
      :instance              => "",
      :capture_interval      => "20",
      :precision             => 2,
      :rollup                => "average",
      :unit_key              => "kilobytespersecond",
      :capture_interval_name => "realtime"
    },
    "mem_usage_absolute_average" => {
      :counter_key           => "mem_usage_absolute_average",
      :instance              => "",
      :capture_interval      => "20",
      :precision             => 1,
      :rollup                => "average",
      :unit_key              => "percent",
      :capture_interval_name => "realtime"
    },
    "net_usage_rate_average"     => {
      :counter_key           => "net_usage_rate_average",
      :instance              => "",
      :capture_interval      => "20",
      :precision             => 2,
      :rollup                => "average",
      :unit_key              => "kilobytespersecond",
      :capture_interval_name => "realtime"
    }
  }.freeze

  def perf_collect_metrics(interval_name, start_time = nil, end_time = nil)
    raise "No EMS defined" if target.ext_management_system.nil?

    log_header = "[#{interval_name}] for: [#{target.class.name}], [#{target.id}], [#{target.name}]"

    end_time   ||= Time.now.utc
    end_time     = end_time.utc
    start_time ||= end_time - 4.hours
    start_time   = start_time.utc

    ems = target.ext_management_system

    _log.info("#{log_header} Collecting KVM metrics from #{start_time} to #{end_time}")

    begin
      vm_metrics = ems.with_provider_connection do |conn|
        domain = _find_domain(conn, target.ems_ref)

        unless domain
          _log.warn("#{log_header} Domain not found for ems_ref=#{target.ems_ref}")
          return [{target.ems_ref => VIM_STYLE_COUNTERS}, {target.ems_ref => {}}]
        end

        s1 = _snapshot_domain(domain)
        sleep(1)
        s2 = _snapshot_domain(domain)

        cpu_pct   = _cpu_percent(s1, s2)
        mem_pct   = _mem_percent(s2)
        disk_kbps = _disk_kbps(s1, s2)
        net_kbps  = _net_kbps(s1, s2)

        _log.info("#{log_header} cpu=#{cpu_pct.round(1)}% mem=#{mem_pct&.round(1).inspect}% disk=#{disk_kbps.round(2)}KB/s net=#{net_kbps.round(2)}KB/s")

        # ManageIQ realtime metrics are on 20-second boundaries
        sample_ts = Time.at((end_time.to_i / 20) * 20).utc

        {
          sample_ts => {
            "cpu_usage_rate_average"     => cpu_pct.round(1),
            "mem_usage_absolute_average" => mem_pct&.round(1),
            "disk_usage_rate_average"    => disk_kbps.round(2),
            "net_usage_rate_average"     => net_kbps.round(2)
          }
        }
      end

      # No custom VimPerformanceState here: core captures the hourly state
      # (incl. total_cpu / total_mem) itself. The old custom row was written at
      # the sample timestamp WITHOUT total_cpu/total_mem, core found it for that
      # sample, and derived "CPU MHz" and "Memory used" became 0.

      [{target.ems_ref => VIM_STYLE_COUNTERS},
       {target.ems_ref => vm_metrics}]
    rescue => err
      _log.error("#{log_header} Error during metrics collection: [#{err}], class: [#{err.class}]")
      _log.log_backtrace(err)
      raise
    end
  end

  private

  # libvirt keeps no metrics history (vCenter keeps the last hour, so VMware
  # only needs to be asked every 50 minutes). Each KVM capture returns one
  # sample for "now", so with the core 50-minute VM threshold a VM would get
  # one sample per hour. Capture on every perf_capture_timer run instead
  # (every 3 minutes by default), giving ~20 samples per hour per VM.
  def perf_capture_now?(target)
    return true if target.last_perf_capture_on.nil?

    target.last_perf_capture_on < kvm_capture_threshold.seconds.ago.utc
  end

  def kvm_capture_threshold
    value = Settings.ems.ems_kvm.try(:metrics_capture_threshold) || "2.minutes"
    value.to_s.to_i_with_method
  end

  # Find domain by UUID — returns nil if not found (VM may be off)
  def _find_domain(conn, uuid)
    conn.lookup_domain_by_uuid(uuid)
  rescue Libvirt::RetrieveError, Libvirt::Error
    nil
  end

  # virDomainMemoryStatTags
  MEM_STAT_RSS            = 7
  MEM_STAT_UNUSED         = 4
  MEM_STAT_AVAILABLE      = 5
  MEM_STAT_ACTUAL_BALLOON = 6

  private_constant :MEM_STAT_RSS,
                   :MEM_STAT_UNUSED,
                   :MEM_STAT_AVAILABLE,
                   :MEM_STAT_ACTUAL_BALLOON

  # Collect one raw stats snapshot from a single domain.

  def _snapshot_domain(domain)
    info = domain.info
    xml  = Nokogiri::XML(domain.xml_desc)

    mem_total  = info.memory.to_i # KiB currently assigned
    mem_used   = nil
    begin
      ms = domain.memory_stats.to_h { |stat| [stat.tag.to_i, stat.instance_variable_get(:@val).to_i] } # #val or #value depending on ruby-libvirt version
      mem_total = ms[MEM_STAT_ACTUAL_BALLOON] if ms[MEM_STAT_ACTUAL_BALLOON].to_i.positive?
      if ms[MEM_STAT_UNUSED].to_i.positive?
        # Guest view from the virtio balloon driver (most accurate)
        base      = ms[MEM_STAT_AVAILABLE].to_i.positive? ? ms[MEM_STAT_AVAILABLE] : mem_total
        mem_used  = base - ms[MEM_STAT_UNUSED]
        mem_total = base
      else
        # Guest stats are only reported when a stats period is set. Turn it on
        # (live only, 10 s) so the next sample has them; use the QEMU process
        # RSS on the host as the estimate for this sample.
        enable_balloon_stats(domain)
        mem_used = ms[MEM_STAT_RSS] if ms[MEM_STAT_RSS].to_i.positive?
      end
    rescue Libvirt::Error, NoMethodError
      # no balloon device in the guest
    end

    rd_bytes = wr_bytes = 0
    xml.xpath("//devices/disk/target").filter_map { |t| t["dev"] }.uniq.each do |dev|
      bs = domain.block_stats(dev)
      rd_bytes += bs.rd_bytes.to_i
      wr_bytes += bs.wr_bytes.to_i
    rescue Libvirt::Error
      next
    end

    rx_bytes = tx_bytes = 0
    xml.xpath("//devices/interface/target").filter_map { |t| t["dev"] }.uniq.each do |dev|
      ns = domain.ifinfo(dev)
      rx_bytes += ns.rx_bytes.to_i
      tx_bytes += ns.tx_bytes.to_i
    rescue Libvirt::Error, NoMethodError
      next
    end

    {
      :cpu_time   => info.cpu_time.to_i, # nanoseconds total
      :mem_used   => mem_used,           # KiB, nil = unknown
      :mem_total  => mem_total,          # KiB
      :rd_bytes   => rd_bytes,
      :wr_bytes   => wr_bytes,
      :rx_bytes   => rx_bytes,
      :tx_bytes   => tx_bytes,
      :sampled_at => Process.clock_gettime(Process::CLOCK_MONOTONIC),
      :nr_vcpu    => [info.nr_virt_cpu.to_i, 1].max
    }
  end

  # CPU % = (delta_cpu_ns) / (delta_wall_s * 1e9 * nr_vcpu) * 100
  def _cpu_percent(previous_stats, current_stats)
    delta_cpu  = (current_stats[:cpu_time]   - previous_stats[:cpu_time]).to_f
    delta_wall = (current_stats[:sampled_at] - previous_stats[:sampled_at]).to_f
    nr_vcpu    = current_stats[:nr_vcpu]

    return 0.0 if delta_wall <= 0 || delta_cpu <= 0

    (delta_cpu / (delta_wall * 1_000_000_000.0 * nr_vcpu) * 100.0).clamp(0.0, 100.0)
  end

  def enable_balloon_stats(domain)
    domain.memory_stats_period = 10
  rescue Libvirt::Error, NoMethodError => err
    _log.debug("KVM: could not enable balloon stats for #{target.name}: #{err.message}")
  end

  # Memory % = (used_mem / total_mem) * 100; nil when the guest gives no data
  def _mem_percent(current_stats)
    total = current_stats[:mem_total].to_f
    return nil if total <= 0 || current_stats[:mem_used].nil?

    (current_stats[:mem_used].to_f / total * 100.0).clamp(0.0, 100.0)
  end

  # Disk KB/s = (rd_delta + wr_delta) / delta_wall / 1024
  def _disk_kbps(previous_stats, current_stats)
    delta_wall = (current_stats[:sampled_at] - previous_stats[:sampled_at]).to_f
    return 0.0 if delta_wall <= 0

    rd = [current_stats[:rd_bytes] - previous_stats[:rd_bytes], 0].max
    wr = [current_stats[:wr_bytes] - previous_stats[:wr_bytes], 0].max
    ((rd + wr).to_f / delta_wall / 1024.0)
  end

  # Net KB/s = (rx_delta + tx_delta) / delta_wall / 1024
  def _net_kbps(previous_stats, current_stats)
    delta_wall = (current_stats[:sampled_at] - previous_stats[:sampled_at]).to_f
    return 0.0 if delta_wall <= 0

    rx = [current_stats[:rx_bytes] - previous_stats[:rx_bytes], 0].max
    tx = [current_stats[:tx_bytes] - previous_stats[:tx_bytes], 0].max
    ((rx + tx).to_f / delta_wall / 1024.0)
  end
end

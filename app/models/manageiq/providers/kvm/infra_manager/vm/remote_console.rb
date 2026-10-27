module ManageIQ::Providers::Kvm::InfraManager::Vm::RemoteConsole
  def console_supported?(type)
    %w[VNC SPICE].include?(type.upcase)
  end

  def validate_remote_console_acquire_ticket(protocol, options = {})
    if ext_management_system.nil?
      raise(
        MiqException::RemoteConsoleNotSupportedError,
        "#{protocol} remote console requires the vm to be registered with a management system."
      )
    end

    if options[:check_if_running] && state != "on"
      raise(
        MiqException::RemoteConsoleNotSupportedError,
        "#{protocol} remote console requires the vm to be running."
      )
    end
  end

  def remote_console_acquire_ticket(userid, originating_server, protocol)
    send(:"remote_console_#{protocol.to_s.downcase}_acquire_ticket", userid, originating_server)
  end

  def remote_console_acquire_ticket_queue(protocol, userid)
    task_opts = {
      :action => "Acquiring Vm #{name} #{protocol.to_s.upcase} remote console ticket for user #{userid}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'remote_console_acquire_ticket',
      :queue_name  => queue_name_for_ems_operations,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :args        => [userid, MiqServer.my_server.id, protocol]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def remote_console_vnc_acquire_ticket(userid, originating_server = nil)
    require 'securerandom'

    validate_remote_console_vnc_support

    ticket = vnc_ticket_info
    raise(MiqException::RemoteConsoleNotSupportedError, "Could not obtain VNC ticket for VM #{name}") unless ticket

    SystemConsole.force_vm_invalid_token(id)

    url_secret = SecureRandom.hex

    console_args = {
      :user       => User.find_by(:userid => userid),
      :vm_id      => id,
      :ssl        => false,
      :protocol   => 'vnc',
      :secret     => ticket[:password],
      :url_secret => url_secret,
      :url        => "/vnc/vnc_lite.html"
    }

    SystemConsole.launch_proxy_if_not_local(
      console_args,
      originating_server,
      ticket[:host],
      ticket[:port]
    )
  end

  def remote_console_spice_acquire_ticket(userid, originating_server = nil)
    require 'securerandom'
    validate_remote_console_spice_support

    ticket = spice_ticket_info
    raise(MiqException::RemoteConsoleNotSupportedError, "Could not obtain SPICE ticket â€” no SPICE graphics found for VM #{name}") unless ticket

    SystemConsole.force_vm_invalid_token(id)
    url_secret = SecureRandom.hex

    console_args = {
      :user       => User.find_by(:userid => userid),
      :vm_id      => id,
      :ssl        => false,
      :protocol   => 'spice',
      :secret     => ticket[:password],
      :url_secret => url_secret,
      :url        => "/vnc/vnc_lite.html"
    }

    SystemConsole.launch_proxy_if_not_local(
      console_args,
      originating_server,
      ticket[:host],
      ticket[:port]
    )
  end

  alias remote_console_html5_acquire_ticket remote_console_vnc_acquire_ticket

  def validate_remote_console_vnc_support
    validate_remote_console_acquire_ticket('vnc')
    raise(MiqException::RemoteConsoleNotSupportedError, "VM #{name} does not have VNC graphics configured.") unless vnc_graphics_present?

    true
  end

  def validate_remote_console_spice_support
    validate_remote_console_acquire_ticket('spice')
    raise(MiqException::RemoteConsoleNotSupportedError, "VM #{name} does not have SPICE graphics configured.") unless spice_graphics_present?

    true
  end

  private

  CONSOLE_TICKET_TTL = 60 # seconds the one-time password stays valid for a NEW connection
  private_constant :CONSOLE_TICKET_TTL

  def vnc_ticket_info
    graphics_ticket("vnc", 8) # VNC passwords are limited to 8 characters
  end

  def spice_ticket_info
    graphics_ticket("spice", 16)
  end

  def graphics_ticket(type, password_length)
    ext_management_system.with_provider_connection do |conn|
      domain = conn.lookup_domain_by_uuid(ems_ref)
      gfx    = Nokogiri::XML(domain.xml_desc).at_xpath("//devices/graphics[@type='#{type}']")
      return nil unless gfx

      port = gfx["port"].to_i
      if port <= 0
        raise MiqException::RemoteConsoleNotSupportedError,
              "#{type.upcase} console of VM #{name} has no port yet - the VM must be running."
      end

      host     = console_host(gfx, type)
      password = SecureRandom.alphanumeric(password_length)

      ticket = gfx.dup
      ticket["passwd"]        = password
      ticket["passwdValidTo"] = CONSOLE_TICKET_TTL.seconds.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S")
      begin
        domain.update_device(ticket.to_xml, Libvirt::Domain::DEVICE_MODIFY_LIVE)
      rescue Libvirt::Error => err
        _log.warn("KVM Console: could not set #{type} password on #{name}: #{err.message}")
        password = nil
      end

      _log.info("KVM Console: #{type} for #{name} at #{host}:#{port}#{" (one-time password set)" if password}")
      {:host => host, :port => port, :password => password, :type => type}
    end
  end

  def console_host(gfx, type)
    listen = gfx["listen"].presence ||
             gfx.at_xpath("listen[@type='address' or @type='network']")&.[]("address").presence

    if listen.nil? || %w[0.0.0.0 :: [::]].include?(listen)
      ext_management_system.hostname.presence || ext_management_system.ipaddress
    elsif listen.match?(/\A(127\.|::1\z|localhost\z)/)
      raise MiqException::RemoteConsoleNotSupportedError,
            "#{type.upcase} console of VM #{name} only listens on #{listen} of the KVM host, so CMP cannot reach it. " \
            "Set vnc_listen = \"0.0.0.0\" in /etc/libvirt/qemu.conf (or listen='0.0.0.0' on the VM's <graphics> " \
            "with virsh edit), open TCP 5900-5999 from the CMP appliance, then shut down and start the VM."
    else
      listen
    end
  end

  def vnc_graphics_present?
    graphics_present?("vnc")
  end

  def spice_graphics_present?
    graphics_present?("spice")
  end

  def graphics_present?(type)
    ext_management_system.with_provider_connection do |conn|
      Nokogiri::XML(conn.lookup_domain_by_uuid(ems_ref).xml_desc).at_xpath("//devices/graphics[@type='#{type}']").present?
    end
  rescue Libvirt::Error, MiqException::Error
    false
  end
end

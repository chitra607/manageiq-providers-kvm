require "libvirt"
require "socket"
require "tmpdir"
require "fileutils"
require "openssl"
require "etc"
require "net/ssh"

class ManageIQ::Providers::Kvm::InfraManager < ManageIQ::Providers::InfraManager
  supports :create
  supports :provisioning
  supports :migrate
  supports :capture
  supports :metrics
  supports :events

  DEFAULT_SSH_PORT    = 22
  TCP_CONNECT_TIMEOUT = 10 # seconds — pre-flight TCP check before libvirt/libssh connects
  TCP_TIMEOUT_ERRORS  = [Errno::ETIMEDOUT, (IO::TimeoutError if defined?(IO::TimeoutError))].compact.freeze

  AUTH_PASSWORD = "password".freeze
  AUTH_SSH_KEY  = "ssh-key".freeze

  MANAGED_KEY_BITS    = 3072
  NET_SSH_TIMEOUT     = 15 # seconds

  # OpenSSH wrapper used as libvirt's ssh "command": accept-new host keys,
  # BatchMode, connect timeout. Lives in <plugin>/libexec.
  SSH_WRAPPER = File.expand_path("../../../../../libexec/kvm-ssh", __dir__).freeze

  # Credential types we can answer in the libvirt open_auth callback.
  AUTH_CRED_TYPES = [
    Libvirt::CRED_AUTHNAME,
    Libvirt::CRED_PASSPHRASE,
    Libvirt::CRED_ECHOPROMPT,
    Libvirt::CRED_NOECHOPROMPT
  ].freeze

  def self.ems_type
    @ems_type ||= "kvm".freeze
  end

  def self.description
    @description ||= "Red Hat KVM".freeze
  end

  def self.hostname_required?
    true
  end

  def self.provision_workflow_class
    ManageIQ::Providers::Kvm::InfraManager::ProvisionWorkflow
  end

  def self.provision_class(_via)
    self::Provision
  end

  def self.vm_migrate_workflow_class
    ::VmMigrateWorkflow
  end

  def self.params_for_create
    {
      :fields => [
        {
          :component => 'sub-form',
          :name      => 'endpoints-subform',
          :title     => _('Endpoints'),
          :fields    => [
            {
              :component              => 'validate-provider-credentials',
              :name                   => 'authentications.default.valid',
              :skipSubmit             => true,
              :isRequired             => true,
              :validationDependencies => %w[type zone_id],
              :fields                 => [
                {
                  :component  => "text-field",
                  :id         => "endpoints.default.hostname",
                  :name       => "endpoints.default.hostname",
                  :label      => _("Hostname (or IPv4 or IPv6 address)"),
                  :isRequired => true,
                  :validate   => [{:type => "required"}],
                },
                {
                  :component    => "text-field",
                  :id           => "endpoints.default.port",
                  :name         => "endpoints.default.port",
                  :label        => _("SSH Port"),
                  :type         => "number",
                  :initialValue => DEFAULT_SSH_PORT,
                  :helperText   => _("SSH port of the KVM host"),
                  :isRequired   => true,
                  :validate     => [
                    {:type => "required"},
                    {:type => "min-number-value", :value => 1, :message => _("Port must be between 1 and 65535")},
                    {:type => "max-number-value", :value => 65_535, :message => _("Port must be between 1 and 65535")},
                  ],
                },
                {
                  :component    => "select",
                  :id           => "endpoints.default.security_protocol",
                  :name         => "endpoints.default.security_protocol",
                  :label        => _("Authentication"),
                  :initialValue => AUTH_PASSWORD,
                  :isRequired   => true,
                  :validate     => [{:type => "required"}],
                  :options      => [
                    {:label => _("Password"), :value => AUTH_PASSWORD},
                    {:label => _("SSH private key (already authorized on the host)"), :value => AUTH_SSH_KEY},
                  ],
                },
                {
                  :component  => "text-field",
                  :id         => "authentications.default.userid",
                  :name       => "authentications.default.userid",
                  :label      => _("Username"),
                  :isRequired => true,
                  :validate   => [{:type => "required"}],
                },
                {
                  :component  => "password-field",
                  :id         => "authentications.default.password",
                  :name       => "authentications.default.password",
                  :label      => _("Password"),
                  :type       => "password",
                  :isRequired => true,
                  :validate   => [{:type => "required"}],
                  :condition  => {:when => "endpoints.default.security_protocol", :is => AUTH_PASSWORD},
                },
                {
                  :component      => "password-field",
                  :id             => "authentications.default.auth_key",
                  :name           => "authentications.default.auth_key",
                  :componentClass => "textarea",
                  :rows           => 10,
                  :type           => "password", # so VerifyCredentialsMixin encrypts it on the queue
                  :label          => _("Private Key"),
                  :isRequired     => true,
                  :validate       => [{:type => "required"}],
                  :condition      => {:when => "endpoints.default.security_protocol", :is => AUTH_SSH_KEY},
                },
              ]
            }
          ]
        }
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # "Validate" button on the Add / Edit provider form.
  #
  # Queued by VerifyCredentialsMixin#verify_credentials? — password and key
  # arrive encrypted. On the Edit form the secret is usually left untouched,
  # so the API sends args["id"] and no secret: fall back to the stored one.
  # ---------------------------------------------------------------------------
  def self.verify_credentials(args)
    endpoint = args.dig("endpoints", "default") || {}
    auth     = args.dig("authentications", "default") || {}
    stored   = args["id"].present? ? find(args["id"]) : nil

    if endpoint["security_protocol"] == AUTH_SSH_KEY
      ssh_key   = ManageIQ::Password.try_decrypt(auth["auth_key"].to_s).presence
      ssh_key ||= stored&.authentication_key(:default)
      connection = raw_connect(endpoint["hostname"], endpoint["port"], auth["userid"], nil, ssh_key)
    else
      password   = ManageIQ::Password.try_decrypt(auth["password"].to_s).presence
      password ||= stored&.authentication_password(:default)
      verify_password_login(endpoint["hostname"], endpoint["port"], auth["userid"], password)
    end
    true
  ensure
    disconnect_connection(connection)
  end

  # ---------------------------------------------------------------------------
  # Instance-level validation — authentication_check, provider summary page,
  # and the "Re-check Authentication Status" action.
  # ---------------------------------------------------------------------------
  def verify_credentials(auth_type = nil, options = {})
    options = options.merge(:auth_type => auth_type || :default)
    with_provider_connection(options) { |_connection| true }
  end

  # ---------------------------------------------------------------------------
  # Open a libvirt connection for this provider record. Always pair with
  # #disconnect — prefer with_provider_connection { |conn| ... }, which does.
  # ---------------------------------------------------------------------------
  def connect(options = {})
    auth_type = options[:auth_type] || :default
    raise MiqException::MiqInvalidCredentialsError, _("No credentials defined") if missing_credentials?(auth_type)

    host     = options[:hostname] || hostname
    port     = options[:port]     || default_endpoint&.port
    userid   = options[:user]     || authentication_userid(auth_type)
    password = options[:pass]     || authentication_password(auth_type)

    return self.class.raw_connect(host, port, userid, nil, authentication_key(auth_type)) if auth_method == AUTH_SSH_KEY

    ssh_key = managed_ssh_key!(auth_type)
    begin
      self.class.raw_connect(host, port, userid, nil, ssh_key)
    rescue MiqException::MiqInvalidCredentialsError => err
      _log.info("KVM [#{name}]: CMP SSH key not accepted by #{host} (#{err.message}); installing it with the password")
      self.class.install_public_key(host, port, userid, password, self.class.public_key_line(ssh_key, managed_key_comment))
      self.class.raw_connect(host, port, userid, nil, ssh_key)
    end
  end

  def managed_ssh_key!(auth_type = :default)
    auth = authentication_type(auth_type)
    raise MiqException::MiqInvalidCredentialsError, _("No credentials defined") if auth.nil?
    return auth.auth_key if auth.auth_key.present?

    auth.with_lock do
      auth.reload
      auth.update!(:auth_key => self.class.generate_ssh_key) if auth.auth_key.blank?
    end
    auth.auth_key
  end

  def managed_key_comment
    "manageiq-kvm-ems#{id}"
  end

  def auth_method
    default_endpoint&.security_protocol.presence || AUTH_PASSWORD
  end

  # Called by ExtManagementSystem#with_provider_connection's ensure block.
  def disconnect(connection)
    self.class.disconnect_connection(connection)
  end

  def self.raw_connect(hostname, port = nil, userid = nil, password = nil, ssh_key = nil)
    hostname = hostname.to_s.strip.delete_prefix("[").delete_suffix("]")
    userid   = userid.to_s.strip
    port     = (port.presence || DEFAULT_SSH_PORT).to_i
    ssh_key  = ManageIQ::Password.try_decrypt(ssh_key.to_s).presence

    raise MiqException::MiqHostError, _("Hostname is required") if hostname.blank?
    raise MiqException::MiqHostError, _("Port must be between 1 and 65535") unless (1..65_535).cover?(port)
    raise MiqException::MiqInvalidCredentialsError, _("Username is required") if userid.blank?

    # Fast, clear failure for wrong host/port/firewall. Libvirt's own connect
    # runs inside the C extension, which a Ruby Timeout cannot interrupt.
    tcp_reachable!(hostname, port)

    connection = ssh_key ? open_with_ssh_key(hostname, port, userid, ssh_key) : open_with_password(hostname, port, userid, password)

    connection.list_all_domains
    connection
  rescue Libvirt::Error => err
    disconnect_connection(connection)
    raise translate_libvirt_error(err)
  end

  def self.open_with_password(hostname, port, userid, password)
    plain_password = ManageIQ::Password.try_decrypt(password.to_s)
    raise MiqException::MiqInvalidCredentialsError, _("Password is required") if plain_password.blank?

    uri = build_libvirt_uri(hostname, port, userid)
    _log.info("KVM: connecting to #{uri.sub(/\?.*\z/, "")}") # never log secrets

    auth_state = {}
    Libvirt.open_auth(uri, AUTH_CRED_TYPES) do |cred|
      answer_auth_prompt(cred, userid, plain_password, auth_state)
    end
  end

  # The key is written to a private temp file only for the duration of the
  # open call: ssh reads it during authentication, which finishes before
  # Libvirt.open returns.
  def self.open_with_ssh_key(hostname, port, userid, ssh_key)
    Dir.mktmpdir("miq-kvm-") do |dir|
      key_file = File.join(dir, "id")
      File.open(key_file, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
        f.write(ssh_key.gsub("\r\n", "\n").strip + "\n") # OpenSSH needs the trailing newline
      end

      uri = build_libvirt_ssh_uri(hostname, port, userid, key_file)
      _log.info("KVM: connecting to #{uri.sub(/\?.*\z/, "")}")
      Libvirt.open(uri)
    end
  end

  def self.verify_password_login(hostname, port, userid, password)
    hostname, port, userid, password = normalize_login(hostname, port, userid, password)
    tcp_reachable!(hostname, port)

    output, = ssh_exec(hostname, port, userid, password, <<~SH)
      if command -v virsh >/dev/null 2>&1; then
        if virsh -c qemu:///system list --all --name >/dev/null 2>&1; then echo MIQ_LIBVIRT_OK; else echo MIQ_LIBVIRT_DENIED; fi
      else
        echo MIQ_NO_VIRSH
      fi
    SH

    if output.include?("MIQ_LIBVIRT_DENIED")
      raise MiqException::MiqInvalidCredentialsError,
            _("Login worked but this user may not manage libvirt. Use root or add the user to the 'libvirt' group on the KVM host.")
    end
    _log.warn("KVM: virsh not found on #{hostname}; libvirt access will be checked on first connect") if output.include?("MIQ_NO_VIRSH")
    true
  end

  # rubocop:disable-next Naming/PredicateMethod
  def self.install_public_key(hostname, port, userid, password, public_key)
    hostname, port, userid, password = normalize_login(hostname, port, userid, password)
    raise ArgumentError, "unexpected characters in public key" unless public_key.match?(%r{\A[A-Za-z0-9+/=@.\- ]+\z})

    output, = ssh_exec(hostname, port, userid, password, <<~SH)
      umask 077
      mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys
      chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
      if [ -s ~/.ssh/authorized_keys ] && [ -n "$(tail -c1 ~/.ssh/authorized_keys)" ]; then echo >> ~/.ssh/authorized_keys; fi
      grep -qxF '#{public_key}' ~/.ssh/authorized_keys || printf '%s\n' '#{public_key}' >> ~/.ssh/authorized_keys
      command -v restorecon >/dev/null 2>&1 && restorecon -R ~/.ssh >/dev/null 2>&1
      echo MIQ_KEY_INSTALLED
    SH

    unless output.include?("MIQ_KEY_INSTALLED")
      raise MiqException::MiqHostError, _("Could not add the CMP SSH key to ~/.ssh/authorized_keys on %{host}: %{out}") %
                                        {:host => hostname, :out => output.to_s.strip.truncate(200)}
    end
    _log.info("KVM: CMP SSH key installed for #{userid}@#{hostname}")
    true
  end

  def self.ssh_exec(hostname, port, userid, password, command)
    ssh_dir = File.join(Etc.getpwuid(Process.uid).dir, ".ssh")
    FileUtils.mkdir_p(ssh_dir, :mode => 0o700)

    Net::SSH.start(
      hostname, userid,
      :port                       => port,
      :password                   => password,
      :auth_methods               => %w[password keyboard-interactive],
      :keys                       => [],
      :keys_only                  => true,
      :use_agent                  => false,
      :non_interactive            => true,
      :number_of_password_prompts => 0,
      :timeout                    => NET_SSH_TIMEOUT,
      :verify_host_key            => :accept_new,
      :user_known_hosts_file      => [File.join(ssh_dir, "known_hosts")]
    ) do |ssh|
      status = {}
      output = ssh.exec!(command, :status => status)
      [output.to_s, status[:exit_code]]
    end
  rescue Net::SSH::AuthenticationFailed
    raise MiqException::MiqInvalidCredentialsError,
          _("Authentication failed. Check the username and password, and that sshd allows password " \
            "or keyboard-interactive logins for this user.")
  rescue Net::SSH::HostKeyError
    raise MiqException::MiqHostError,
          _("SSH host key of %{host} has changed. If the host was reinstalled, remove its old entry on the " \
            "appliance: ssh-keygen -R '[%{host}]:%{port}' (as the user the CMP workers run as)") % {:host => hostname, :port => port}
  rescue Net::SSH::ConnectionTimeout, Net::SSH::Disconnect, SocketError, SystemCallError => err
    raise MiqException::MiqUnreachableError, _("SSH connection to %{host}:%{port} failed: %{msg}") %
                                             {:host => hostname, :port => port, :msg => err.message}
  rescue Net::SSH::Exception => err
    raise MiqException::MiqHostError, _("SSH error: %{msg}") % {:msg => err.message}
  end

  def self.normalize_login(hostname, port, userid, password)
    hostname = hostname.to_s.strip.delete_prefix("[").delete_suffix("]")
    port     = (port.presence || DEFAULT_SSH_PORT).to_i
    userid   = userid.to_s.strip
    password = ManageIQ::Password.try_decrypt(password.to_s)

    raise MiqException::MiqHostError, _("Hostname is required") if hostname.blank?
    raise MiqException::MiqHostError, _("Port must be between 1 and 65535") unless (1..65_535).cover?(port)
    raise MiqException::MiqInvalidCredentialsError, _("Username is required") if userid.blank?
    raise MiqException::MiqInvalidCredentialsError, _("Password is required") if password.blank?

    [hostname, port, userid, password]
  end

  # RSA PEM: readable by every OpenSSH version and allowed by RHEL 9 crypto policies / FIPS.
  def self.generate_ssh_key
    OpenSSL::PKey::RSA.new(MANAGED_KEY_BITS).to_pem
  end

  # "ssh-rsa AAAA... comment" for authorized_keys (to_blob/ssh_type come from net-ssh)
  def self.public_key_line(private_key, comment)
    key = OpenSSL::PKey.read(private_key)
    "#{key.ssh_type} #{[key.to_blob].pack("m0")} #{comment}"
  end

  def self.answer_auth_prompt(cred, userid, password, state = {})
    case cred["type"]
    when Libvirt::CRED_AUTHNAME
      userid
    when Libvirt::CRED_PASSPHRASE, Libvirt::CRED_NOECHOPROMPT
      return nil if state[:password_sent]

      state[:password_sent] = true
      password
    when Libvirt::CRED_ECHOPROMPT
      cred["prompt"].to_s.match?(/user|login|name/i) ? userid : cred["defresult"]
    else
      cred["defresult"]
    end
  end

  def self.build_libvirt_uri(hostname, port = DEFAULT_SSH_PORT, userid = nil)
    host      = hostname.to_s.strip.delete_prefix("[").delete_suffix("]")
    host      = "[#{host}]" if host.include?(":")
    user_part = userid.present? ? "#{uri_escape(userid.to_s.strip)}@" : ""
    port_part = port.present? && port.to_i != DEFAULT_SSH_PORT ? ":#{port.to_i}" : ""

    "qemu+libssh://#{user_part}#{host}#{port_part}/system" \
      "?sshauth=password,keyboard-interactive&known_hosts_verify=auto"
  end

  def self.build_libvirt_ssh_uri(hostname, port, userid, key_file)
    host      = hostname.to_s.strip.delete_prefix("[").delete_suffix("]")
    host      = "[#{host}]" if host.include?(":")
    port_part = port.present? && port.to_i != DEFAULT_SSH_PORT ? ":#{port.to_i}" : ""
    query     = {"keyfile" => key_file, "no_tty" => "1"}
    query["command"] = SSH_WRAPPER if File.executable?(SSH_WRAPPER)

    "qemu+ssh://#{uri_escape(userid.to_s.strip)}@#{host}#{port_part}/system?" +
      query.map { |k, v| "#{k}=#{uri_escape(v)}" }.join("&")
  end

  def self.uri_escape(value)
    value.to_s.b.gsub(%r{[^A-Za-z0-9\-._~/]}) { |c| "%%%02X" % c.ord }
  end

  def self.disconnect_connection(connection)
    return if connection.nil?

    connection.close unless connection.closed?
  rescue Libvirt::Error => err
    _log.warn("KVM: error while closing libvirt connection: #{err.message}")
  ensure
    nil
  end

  # ---------------------------------------------------------------------------
  # Pre-flight TCP reachability check
  # ---------------------------------------------------------------------------
  def self.tcp_reachable!(hostname, port, timeout: TCP_CONNECT_TIMEOUT)
    Socket.tcp(hostname, port, :connect_timeout => timeout).close
    true
  rescue *TCP_TIMEOUT_ERRORS
    raise MiqException::MiqUnreachableError,
          _("Cannot reach %{host}:%{port} — connection timed out. Check routing and firewall rules.") %
          {:host => hostname, :port => port}
  rescue Errno::ECONNREFUSED
    raise MiqException::MiqUnreachableError,
          _("Connection refused at %{host}:%{port}. Ensure sshd is listening on that port " \
            "(9090 is Cockpit, not SSH).") % {:host => hostname, :port => port}
  rescue SocketError, SystemCallError => err # DNS failure, EHOSTUNREACH, ENETUNREACH, ...
    raise MiqException::MiqUnreachableError,
          _("Host %{host} is unreachable: %{msg}") % {:host => hostname, :msg => err.message}
  end

  def self.translate_libvirt_error(err)
    raw = err.respond_to?(:libvirt_message) && err.libvirt_message.present? ? err.libvirt_message : err.message
    klass, message = libvirt_error_details(raw.to_s)
    klass.new(message)
  end

  def self.libvirt_error_details(raw_message)
    case raw_message
    when /polkit|not authorized|access denied|Permission denied.*libvirt-sock|libvirt-sock.*Permission denied/i
      [MiqException::MiqInvalidCredentialsError,
       _("Login worked but this user may not manage libvirt. Use root or add the user to the 'libvirt' group on the KVM host.")]
    when /Load key|invalid format|error in libcrypto|bad permissions/i
      [MiqException::MiqInvalidCredentialsError,
       _("The private key could not be used. Paste an unencrypted OpenSSH/PEM private key. (%{msg})") % {:msg => raw_message}]
    when /Permission denied \(publickey/i
      [MiqException::MiqInvalidCredentialsError,
       _("SSH key rejected. Check the username and that the public key is in ~/.ssh/authorized_keys of this user on the KVM host.")]
    when /failed to retrieve user response|authentication failed|auth.*fail|no suitable method|Permission denied/i
      [MiqException::MiqInvalidCredentialsError,
       _("Authentication failed. Check the username and password, and that sshd allows password " \
         "or keyboard-interactive logins for this user.")]
    when /host key|known_hosts|hostkey|REMOTE HOST IDENTIFICATION HAS CHANGED/i
      [MiqException::MiqHostError,
       _("SSH host key check failed. If the KVM host was reinstalled, remove its old entry from " \
         "~manageiq/.ssh/known_hosts (SSH key) or ~manageiq/.config/libvirt/known_hosts (password) " \
         "on the appliance: ssh-keygen -R '[host]:port'")]
    when /libssh.*(not|unsupported|disabled)|transport.*(not supported|unsupported)|no connection driver/i
      [MiqException::MiqHostError,
       _("The libvirt client on this appliance has no libssh transport. Install a libvirt client " \
         "built with libssh support. (%{msg})") % {:msg => raw_message}]
    when /connection refused/i
      [MiqException::MiqUnreachableError,
       _("SSH connection refused. Ensure sshd is listening on the configured port (9090 is Cockpit, not SSH).")]
    when /no route to host|network is unreachable|timed out|name or service not known|could not resolve/i
      [MiqException::MiqUnreachableError,
       _("Host is unreachable: %{msg}") % {:msg => raw_message}]
    when /Remote command terminated with non-zero code|virt-ssh-helper|libvirt-sock|No such file or directory|Failed to connect socket/i
      [MiqException::MiqHostError,
       _("SSH login worked, but libvirt on the KVM host refused the connection. Check that libvirtd " \
         "(or virtqemud) is running and that the user is root or in the 'libvirt' group. (%{msg})") % {:msg => raw_message}]
    when /end of file|broken pipe|connection reset/i
      [MiqException::MiqHostError,
       _("SSH connection dropped unexpectedly. Check sshd logs on the KVM host. (%{msg})") % {:msg => raw_message}]
    else
      [MiqException::MiqHostError, _("KVM connection failed: %{msg}") % {:msg => raw_message}]
    end
  end

  # Kept for backward compatibility with older callers.
  def self.libvirt_error_message(raw_message)
    libvirt_error_details(raw_message.to_s).last
  end

  def find_vm(vm_id)
    vms.find_by(:id => vm_id)
  end

  def vm_console(vm, options = {})
    _log.info("Queuing console request for VM id: #{vm.id} with userid: #{options[:userid]}")
    MiqEvent.raise_evm_job_event(vm, :type => "vm", :suffix => "console")
  end
end

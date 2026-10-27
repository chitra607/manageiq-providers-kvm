require "spec_helper"

RSpec.describe(ManageIQ::Providers::Kvm::InfraManager) do
  describe ".build_libvirt_uri (password / qemu+libssh)" do
    it "builds the default-port URI" do
      expect(described_class.build_libvirt_uri("kvm01.example.com", 22, "root"))
        .to(eq("qemu+libssh://root@kvm01.example.com/system?sshauth=password,keyboard-interactive&known_hosts_verify=auto"))
    end

    it "keeps a non-default port, brackets IPv6 and escapes the user name" do
      expect(described_class.build_libvirt_uri("fd00::10", 2222, "CORP\\svc@x"))
        .to(start_with("qemu+libssh://CORP%5Csvc%40x@[fd00::10]:2222/system?"))
    end
  end

  describe ".build_libvirt_ssh_uri (SSH key / qemu+ssh)" do
    it "passes the key file and disables prompts" do
      uri = described_class.build_libvirt_ssh_uri("10.0.0.5", 22, "root", "/tmp/miq-kvm-x/id")
      expect(uri).to(start_with("qemu+ssh://root@10.0.0.5/system?keyfile=/tmp/miq-kvm-x/id&no_tty=1"))
    end
  end

  describe ".answer_auth_prompt" do
    it "hands out the password only once, so a wrong password fails fast instead of hanging" do
      state = {}
      cred  = {"type" => Libvirt::CRED_PASSPHRASE, "prompt" => "Enter root's password"}

      expect(described_class.answer_auth_prompt(cred, "root", "secret", state)).to(eq("secret"))
      expect(described_class.answer_auth_prompt(cred, "root", "secret", state)).to(be_nil)
    end

    it "never answers a yes/no prompt with the user name" do
      cred = {"type" => Libvirt::CRED_ECHOPROMPT, "prompt" => "Accept SSH host key? (y/n)", "defresult" => nil}
      expect(described_class.answer_auth_prompt(cred, "root", "secret")).to(be_nil)
    end
  end

  describe ".libvirt_error_details" do
    {
      "operation failed: failed to retrieve user response for authentication callback"    => MiqException::MiqInvalidCredentialsError,
      "Cannot recv data: kvm@h: Permission denied (publickey).: Connection reset by peer" => MiqException::MiqInvalidCredentialsError,
      "authentication unavailable: no polkit agent available to authenticate action"      => MiqException::MiqInvalidCredentialsError,
      "libssh transport error: Remote command terminated with non-zero code: 1"           => MiqException::MiqHostError,
      "Cannot recv data: Host key verification failed.: Connection reset by peer"         => MiqException::MiqHostError,
      "unable to connect to server: Connection refused"                                   => MiqException::MiqUnreachableError,
    }.each do |message, klass|
      it "maps #{message.truncate(50).inspect} to #{klass.name.demodulize}" do
        expect(described_class.libvirt_error_details(message).first).to(eq(klass))
      end
    end
  end

  describe ".verify_credentials" do
    let(:connection) { double("Libvirt::Connect", :closed? => false, :close => nil) }

    def args(protocol:, password: nil, key: nil, identifier: nil)
      {
        "endpoints"       => {"default" => {"hostname" => "kvm01", "port" => 22, "security_protocol" => protocol}},
        "authentications" => {"default" => {"userid" => "root", "password" => password, "auth_key" => key}},
        "id"              => identifier
      }
    end

    it "checks a password login over net-ssh (no libvirt libssh connection)" do
      expect(described_class).to(receive(:verify_password_login).with("kvm01", 22, "root", "secret").and_return(true))
      expect(described_class).not_to(receive(:raw_connect))

      expect(described_class.verify_credentials(args(:protocol => "password", :password => "secret"))).to(be(true))
    end

    it "uses the SSH key transport when selected" do
      expect(described_class).to(receive(:raw_connect).with("kvm01", 22, "root", nil, "KEY").and_return(connection))
      expect(described_class.verify_credentials(args(:protocol => "ssh-key", :key => "KEY"))).to(be(true))
    end

    it "falls back to the stored secret on the Edit form" do
      stored = double(:authentication_password => "stored-pw")
      allow(described_class).to(receive(:find).with(42).and_return(stored))
      expect(described_class).to(receive(:verify_password_login).with("kvm01", 22, "root", "stored-pw").and_return(true))

      described_class.verify_credentials(args(:protocol => "password", :id => 42))
    end

    it "does not hide the real error behind 'Invalid credentials'" do
      allow(described_class).to(receive(:verify_password_login)
        .and_raise(MiqException::MiqUnreachableError, "Connection refused at kvm01:22"))

      expect { described_class.verify_credentials(args(:protocol => "password", :password => "x")) }
        .to(raise_error(MiqException::MiqUnreachableError, /Connection refused/))
    end
  end

  describe "password mode: CMP-managed SSH key" do
    it "generates an RSA key and derives an authorized_keys line from it" do
      pem  = described_class.generate_ssh_key
      line = described_class.public_key_line(pem, "manageiq-kvm-ems7")

      expect(pem).to(start_with("-----BEGIN RSA PRIVATE KEY-----"))
      expect(line).to(match(%r{\Assh-rsa [A-Za-z0-9+/=]+ manageiq-kvm-ems7\z}))
    end

    it "refuses to put anything but a plain key line into a remote shell command" do
      expect { described_class.install_public_key("h", 22, "root", "pw", "ssh-rsa AAAA x'; rm -rf ~ #") }
        .to(raise_error(ArgumentError))
    end
  end
end

require "yaml"
require "ipaddr"

# Guest customization with cloud-init (NoCloud seed ISO built by
# InfraManager::CloudInitIso and attached by DomainCloner).
#
# Customize tab, "Customize: Specification":
#   * a Cloud-Init customization template (Compute > Infrastructure > PXE >
#     Customization Templates, type CloudInit) is used as user-data, with the
#     usual <%= evm[:...] %> substitutions, or
#   * without a template, user-data is generated from Host Name / Root Password.
#   * IP address fields (Address Mode "Static") become network-config v2 for the
#     first NIC, matched by its MAC address.
module ManageIQ::Providers::Kvm::InfraManager::Provision::Configuration
  def customize_with_cloud_init?
    return false if create_template?

    get_option(:sysprep_enabled).to_s == "fields" || get_option(:customization_template_id).present?
  end

  def cloud_init_payload(mac)
    files = {
      "meta-data" => cloud_init_meta_data,
      "user-data" => cloud_init_user_data(mac)
    }
    network = cloud_init_network_config(mac)
    files["network-config"] = network if network
    files
  end

  private

  def cloud_init_hostname
    name = get_option(:hostname).presence || dest_hostname.presence || dest_name
    name.to_s.strip.gsub(/[^A-Za-z0-9.-]/, "-")[0, 63]
  end

  def cloud_init_meta_data
    {"instance-id" => "iid-#{dest_name}-#{id}", "local-hostname" => cloud_init_hostname}.to_yaml.delete_prefix("---\n")
  end

  def cloud_init_user_data(mac = nil)
    content = customization_template&.script_with_substitution(prepare_customization_template_substitution_options(mac))
    return content.to_s if content.present?

    config = {
      "hostname"         => cloud_init_hostname.split(".").first,
      "manage_etc_hosts" => true
    }
    fqdn_domain = dns_suffixes.first
    config["fqdn"] = "#{config["hostname"]}.#{fqdn_domain}" if fqdn_domain

    password = ManageIQ::Password.try_decrypt(get_option(:root_password).to_s)
    if password.present?
      config["disable_root"] = false
      config["ssh_pwauth"]   = true
      # list form: understood by old (RHEL 7/8) and new cloud-init
      config["chpasswd"]     = {"list" => "root:#{password}", "expire" => false}
    end

    "#cloud-config\n#{config.to_yaml.delete_prefix("---\n")}"
  end

  # network-config v2 for the first NIC when Address Mode is static
  def cloud_init_network_config(mac)
    return nil unless get_option(:addr_mode).to_s == "static"

    ip = get_option(:ip_addr).to_s.strip
    return nil if ip.blank? || mac.blank?

    prefix = netmask_prefix(get_option(:subnet_mask))
    raise MiqException::MiqProvisionError, _("Subnet Mask is required for a static IP address") if prefix.nil?

    eth = {
      "match"     => {"macaddress" => mac}, # applies to the NIC whatever the guest calls it
      "dhcp4"     => false,
      "addresses" => ["#{ip}/#{prefix}"]
    }
    gateway = get_option(:gateway).to_s.strip
    eth["routes"] = [{"to" => "0.0.0.0/0", "via" => gateway}] if gateway.present?
    ns = {}
    ns["addresses"] = dns_servers if dns_servers.any?
    ns["search"]    = dns_suffixes if dns_suffixes.any?
    eth["nameservers"] = ns if ns.any?

    {"version" => 2, "ethernets" => {"eth0" => eth}}.to_yaml.delete_prefix("---\n")
  end

  def dns_servers
    split_list(get_option(:dns_servers))
  end

  def dns_suffixes
    split_list(get_option(:dns_suffixes))
  end

  def split_list(value)
    value.to_s.split(/[\s,;]+/).map(&:strip).reject(&:blank?)
  end

  # "255.255.255.0" or "24" -> 24
  def netmask_prefix(mask)
    mask = mask.to_s.strip
    return nil if mask.blank?
    return mask.to_i if mask.match?(/\A\d{1,2}\z/) && mask.to_i <= 32

    IPAddr.new(mask).to_i.to_s(2).count("1")
  rescue IPAddr::InvalidAddressError
    nil
  end
end

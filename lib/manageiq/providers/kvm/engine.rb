module ManageIQ
  module Providers
    module Kvm
      class Engine < ::Rails::Engine
        isolate_namespace ManageIQ::Providers::Kvm

        config.autoload_paths << root.join('lib').to_s

        def self.vmdb_plugin?
          true
        end

        def self.plugin_name
          _('Kvm Provider')
        end

        def self.init_loggers
          $kvm_log ||= Vmdb::Loggers.create_logger("kvm.log")
        end

        def self.seedable_classes
          # This provider does not define any custom seeding classes.
          []
        end

        def self.apply_logger_config(config)
          Vmdb::Loggers.apply_config_value(config, $kvm_log, :level_kvm)
        end
      end
    end
  end
end

if ENV['CI']
  require 'simplecov'
  SimpleCov.start
end

Rails.root.glob("spec/shared/**/*.rb").each { |f| require f }
Dir[File.join(__dir__, "support/**/*.rb")].each { |f| require f }

require "manageiq/providers/kvm"

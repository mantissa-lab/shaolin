require "shaolin/core"
require "shaolin/server"
require_relative "support/net"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.include NetHelpers
end

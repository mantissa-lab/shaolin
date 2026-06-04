ENV["SHAOLIN_LOG"] ||= "off" # silence structured logs in tests

require "shaolin/cli"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
end

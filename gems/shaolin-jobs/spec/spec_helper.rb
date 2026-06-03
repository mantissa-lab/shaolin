require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/jobs"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
end

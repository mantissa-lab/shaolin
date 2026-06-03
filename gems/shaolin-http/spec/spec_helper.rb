require "shaolin/core"
require "shaolin/http"
require "rack/test"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.include Rack::Test::Methods
end

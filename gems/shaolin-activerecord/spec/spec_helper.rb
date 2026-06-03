require "shaolin/core"
require "shaolin/activerecord"

# Local Postgres for integration specs (see project memory): port 5433, socket /tmp.
ENV["SHAOLIN_TEST_DATABASE_URL"] ||= "postgres://postgres@/shaolin_test?host=/tmp&port=5433"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
end

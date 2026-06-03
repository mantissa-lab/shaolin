$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "shaolin/redis"

# Integration tests run against a live Redis. Start an ephemeral one:
#   redis-server --port 6399 --daemonize yes --save ""
REDIS_TEST_URL = ENV.fetch("REDIS_TEST_URL", "redis://127.0.0.1:6399/0")

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!

  # A clean keyspace per example so tests don't bleed into each other.
  config.before(:each) do
    ::Redis.new(url: REDIS_TEST_URL).flushdb
  end
end

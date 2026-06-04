$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
ENV["SHAOLIN_LOG"] ||= "off"

require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/llm"
require "shaolin/harness"

module PgTest
  CONFIG = {
    adapter: "postgresql",
    database: ENV.fetch("DB_NAME", "shaolin_test"),
    username: ENV.fetch("DB_USER", "postgres"),
    password: ENV["PGPASSWORD"],
    host: ENV.fetch("DB_HOST", "/tmp"),
    port: Integer(ENV.fetch("DB_PORT", "5433"))
  }.freeze

  module_function

  def reset_schema!
    ActiveRecord::Base.establish_connection(CONFIG)
    conn = ActiveRecord::Base.connection
    conn.tables.each { |t| conn.drop_table(t, force: :cascade) }
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
end

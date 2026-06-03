require "active_record"

module PgTest
  # Local default: /tmp:5433 cluster; CI overrides via DB_* env (TCP service).
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

require "active_record"

# Connection config for the test Postgres. Local default: port 5433, unix socket
# in /tmp, db shaolin_test, trust auth (see memory). CI overrides via DB_* env.
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

  def connect!
    ActiveRecord::Base.establish_connection(CONFIG)
  end

  # Drop every table so each spec starts clean.
  def reset_schema!
    connect!
    conn = ActiveRecord::Base.connection
    conn.tables.each { |t| conn.drop_table(t, force: :cascade) }
  end
end

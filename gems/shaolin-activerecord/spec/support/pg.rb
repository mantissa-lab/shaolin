require "active_record"

# Connection config for the local test Postgres (see project memory):
# port 5433, unix socket in /tmp, db shaolin_test, trust auth.
module PgTest
  CONFIG = {
    adapter: "postgresql",
    database: "shaolin_test",
    username: "postgres",
    host: "/tmp",
    port: 5433
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

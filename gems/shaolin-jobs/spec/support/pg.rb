require "active_record"

module PgTest
  CONFIG = {
    adapter: "postgresql", database: "shaolin_test",
    username: "postgres", host: "/tmp", port: 5433
  }.freeze

  module_function

  def reset_schema!
    ActiveRecord::Base.establish_connection(CONFIG)
    conn = ActiveRecord::Base.connection
    conn.tables.each { |t| conn.drop_table(t, force: :cascade) }
  end
end

require "active_record"

module Shaolin
  module Jobs
    # Creates the jobs tables (idempotent). Called by the :jobs provider at boot,
    # like the event-store schema.
    module Schema
      def self.create!
        conn = ::ActiveRecord::Base.connection
        create_outbox(conn)
        create_schedules(conn)
      end

      def self.create_outbox(conn)
        return if conn.table_exists?("shaolin_jobs")

        conn.create_table(:shaolin_jobs) do |t|
          t.string   :reactor,    null: false
          t.string   :event_id,   null: false
          t.string   :event_type, null: false
          t.text     :payload
          t.string   :status,     null: false, default: "pending"
          t.integer  :attempts,   null: false, default: 0
          t.datetime :run_at,     null: false
          t.text     :last_error
          t.timestamps
        end
        conn.add_index(:shaolin_jobs, %i[status run_at])
      end

      def self.create_schedules(conn)
        return if conn.table_exists?("shaolin_schedules")

        conn.create_table(:shaolin_schedules) do |t|
          t.string   :name, null: false
          t.datetime :last_run_at
        end
        conn.add_index(:shaolin_schedules, :name, unique: true)
      end
    end
  end
end

require "active_record"

module Shaolin
  module Jobs
    # Creates the jobs tables (idempotent). Called by the :jobs provider at boot,
    # like the event-store schema. Held under a Postgres advisory lock so
    # concurrent replica boots can't race the table_exists?-then-create check.
    module Schema
      SCHEMA_LOCK_KEY = 7_283_011

      def self.create!
        ::ActiveRecord::Base.connection_pool.with_connection do |conn|
          conn.execute("SELECT pg_advisory_lock(#{SCHEMA_LOCK_KEY})")
          begin
            create_outbox(conn)
            create_schedules(conn)
          ensure
            conn.execute("SELECT pg_advisory_unlock(#{SCHEMA_LOCK_KEY})")
          end
        end
      end

      def self.create_outbox(conn)
        unless conn.table_exists?("shaolin_jobs")
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
        end
        # Ensure indexes (also upgrades a pre-existing table that lacks them).
        conn.add_index(:shaolin_jobs, %i[status run_at]) unless conn.index_exists?(:shaolin_jobs, %i[status run_at])
        # Idempotent enqueue: an event delivers to a given reactor at most once,
        # even if it is (re)published more than once.
        unless conn.index_exists?(:shaolin_jobs, %i[reactor event_id], unique: true)
          conn.add_index(:shaolin_jobs, %i[reactor event_id], unique: true)
        end
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

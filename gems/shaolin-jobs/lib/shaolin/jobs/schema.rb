require "active_record"

module Shaolin
  module Jobs
    # Creates the outbox table (idempotent). Called by the :jobs provider at boot,
    # like the event-store schema.
    module Schema
      def self.create!
        return if ::ActiveRecord::Base.connection.table_exists?("shaolin_jobs")

        ::ActiveRecord::Base.connection.create_table(:shaolin_jobs) do |t|
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
        ::ActiveRecord::Base.connection.add_index(:shaolin_jobs, %i[status run_at])
      end
    end
  end
end

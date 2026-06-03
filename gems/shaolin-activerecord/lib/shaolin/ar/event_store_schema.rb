require "active_record"
require "ruby_event_store/active_record"

module Shaolin
  module AR
    # Creates/drops the RubyEventStore event-store schema standalone (no Rails),
    # via the gem's DatabaseAdapter + MigrationGenerator. Uses the `binary`
    # data type (robust symbol-key round-trip with the YAML serializer).
    module EventStoreSchema
      TABLES = %w[event_store_events_in_streams event_store_events].freeze

      def self.create!(data_type: "binary")
        return if exists?

        adapter = RubyEventStore::ActiveRecord::DatabaseAdapter.from_string(adapter_name, data_type)
        _path, code = RubyEventStore::ActiveRecord::MigrationGenerator.new.generate(adapter, "/tmp")

        Object.send(:remove_const, :CreateEventStoreEvents) if Object.const_defined?(:CreateEventStoreEvents)
        eval(code) # rubocop:disable Security/Eval -- gem-generated migration code
        ::ActiveRecord::Migration.suppress_messages { CreateEventStoreEvents.migrate(:up) }
      end

      def self.drop!
        conn = ::ActiveRecord::Base.connection
        TABLES.each { |t| conn.drop_table(t, force: :cascade) if conn.table_exists?(t) }
      end

      def self.exists?
        ::ActiveRecord::Base.connection.table_exists?("event_store_events")
      end

      def self.adapter_name
        ::ActiveRecord::Base.connection.adapter_name.downcase
      end
    end
  end
end

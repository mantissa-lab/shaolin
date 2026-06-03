require "active_record"
require "active_support/isolated_execution_state"

module Shaolin
  module AR
    # Establishes the standalone ActiveRecord connection (no Rails) and sets the
    # concurrency isolation level: :fiber under Falcon (async-first), :thread
    # under Puma. Config is a plain hash (adapter/database/host/...).
    module Connection
      def self.establish!(config)
        ::ActiveRecord::Base.establish_connection(config)
        self
      end

      def self.connected?
        ::ActiveRecord::Base.connection_pool.with_connection do |conn|
          conn.select_value("SELECT 1").to_i == 1
        end
      rescue StandardError
        false
      end

      # level: :fiber or :thread
      def self.isolation_level=(level)
        ::ActiveSupport::IsolatedExecutionState.isolation_level = level
      end

      def self.isolation_level
        ::ActiveSupport::IsolatedExecutionState.isolation_level
      end
    end
  end
end

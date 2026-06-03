require "active_record"
require "active_support/isolated_execution_state"

module Shaolin
  module AR
    # Establishes the standalone ActiveRecord connection (no Rails) and sets the
    # concurrency isolation level: :fiber under Falcon (async-first), :thread
    # under Puma. Config is a plain hash (adapter/database/host/...).
    module Connection
      # Connect. `config` is a plain hash; missing keys get production-safe
      # defaults from ENV:
      #   pool (DB_POOL, 5)               — must be >= concurrent fibers/threads
      #                                     hitting the DB (e.g. worker --threads N)
      #   checkout_timeout (5s)           — bound the wait for a free connection
      #   reaping_frequency (60s)         — reclaim connections leaked by crashed
      #                                     threads / dropped by a DB failover
      def self.establish!(config)
        defaults = {
          pool: Integer(ENV.fetch("DB_POOL", "5")),
          checkout_timeout: Float(ENV.fetch("DB_CHECKOUT_TIMEOUT", "5")),
          reaping_frequency: Integer(ENV.fetch("DB_REAPING_FREQUENCY", "60"))
        }
        ::ActiveRecord::Base.establish_connection(defaults.merge(config.transform_keys(&:to_sym)))
        self
      end

      # Serialize a critical section across processes/replicas via a Postgres
      # session advisory lock (e.g. one-time schema creation at boot). Blocks
      # until the lock is held, runs the block, then releases.
      def self.with_advisory_lock(key)
        ::ActiveRecord::Base.connection_pool.with_connection do |conn|
          conn.execute("SELECT pg_advisory_lock(#{key.to_i})")
          begin
            yield
          ensure
            conn.execute("SELECT pg_advisory_unlock(#{key.to_i})")
          end
        end
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

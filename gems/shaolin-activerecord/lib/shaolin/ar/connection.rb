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
      # `replica:` (optional) wires a read-only replica via AR role routing: ALL
      # writes (event append + sync projections + outbox) stay on the primary
      # (writing role), so the atomic outbox is unaffected; only code that opts in
      # with `Shaolin::AR.reading { ... }` reads from the replica. Without it, a
      # plain single-DB connection as before.
      def self.establish!(config, replica: nil)
        defaults = {
          pool: Integer(ENV.fetch("DB_POOL", "5")),
          checkout_timeout: Float(ENV.fetch("DB_CHECKOUT_TIMEOUT", "5")),
          reaping_frequency: Integer(ENV.fetch("DB_REAPING_FREQUENCY", "60"))
        }
        primary = defaults.merge(config.transform_keys(&:to_sym))

        if replica
          env = ::ActiveRecord::ConnectionHandling::DEFAULT_ENV.call
          rep = defaults.merge(replica.transform_keys(&:to_sym))
          ::ActiveRecord::Base.configurations = {
            env => { "primary" => primary.transform_keys(&:to_s), "replica" => rep.transform_keys(&:to_s) }
          }
          ::ActiveRecord::Base.connects_to(database: { writing: :primary, reading: :replica })
          @replica = true
        else
          ::ActiveRecord::Base.establish_connection(primary)
          @replica = false
        end
        self
      end

      # Run a block's queries against the read replica (when configured) — for
      # heavy/analytical reads that shouldn't compete with the write path. A no-op
      # passthrough when no replica is wired, so app code can use it unconditionally.
      def self.reading(&block)
        return yield unless @replica

        ::ActiveRecord::Base.connected_to(role: :reading, &block)
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

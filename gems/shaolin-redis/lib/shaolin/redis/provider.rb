require "shaolin/core"

module Shaolin
  module Redis
    # The :redis provider. Builds a shared connection pool and registers the
    # cache, store, and broker into the kernel so any module resolves them by
    # documented keys:
    #   redis.pool       — the ConnectionPool (raw client access)
    #   redis.cache      — Shaolin::Redis::Cache
    #   cache.store      — the generic cache port (same object; swap backends here)
    #   redis.store      — Shaolin::Redis::Store ("Redis as a database")
    #   redis.publisher  — Shaolin::Redis::StreamPublisher (Messaging::Publisher port)
    #
    # Register it alongside the other providers (order-independent — it only
    # needs the kernel).
    def self.register_provider!(url: Connection::DEFAULT_URL, namespace: "shaolin",
                                pool_size: 5, stream: "shaolin:events")
      Shaolin.register_provider(:redis) do
        start do
          pool = Connection.pool(url: url, size: pool_size)
          cache = Cache.new(pool: pool, namespace: "#{namespace}:cache")
          store = Store.new(pool: pool, namespace: "#{namespace}:store")

          Shaolin::Kernel.register("redis.pool", pool)
          Shaolin::Kernel.register("redis.cache", cache)
          Shaolin::Kernel.register("cache.store", cache)
          Shaolin::Kernel.register("redis.store", store)
          Shaolin::Kernel.register("redis.publisher", StreamPublisher.new(pool: pool, stream: stream))
          Shaolin::Health.register("redis") { pool.with { |r| r.ping == "PONG" } }
        end
      end
    end
  end
end

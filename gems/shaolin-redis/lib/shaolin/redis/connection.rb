require "redis"
require "connection_pool"

module Shaolin
  module Redis
    # Connection management. Wraps the redis-rb client in a ConnectionPool so
    # fiber/thread workers share a bounded set of connections.
    #
    # NOTE: inside this namespace the redis-rb client is `::Redis` — a bare
    # `Redis` resolves to this module (Shaolin::Redis). Always use `::Redis`.
    module Connection
      module_function

      DEFAULT_URL = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

      def pool(url: DEFAULT_URL, size: 5, timeout: 5)
        ::ConnectionPool.new(size: size, timeout: timeout) { ::Redis.new(url: url) }
      end

      # A single client (no pool) — for blocking operations like Pub/Sub subscribe
      # that must own their connection.
      def client(url: DEFAULT_URL)
        ::Redis.new(url: url)
      end
    end
  end
end

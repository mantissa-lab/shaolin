require "json"

module Shaolin
  module Redis
    # Lightweight fire-and-forget Pub/Sub (PUBLISH / SUBSCRIBE). Unlike Streams,
    # messages are NOT persisted — a subscriber that is offline misses them, and
    # there are no acks. Use it for ephemeral fan-out (live dashboards, cache
    # invalidation, presence). For reliable delivery use StreamPublisher/Consumer.
    class PubSub
      def initialize(pool:, url: nil)
        @pool = pool
        @url = url
      end

      # Returns the number of subscribers that received the message.
      def publish(channel, message)
        body = message.is_a?(String) ? message : JSON.generate(message)
        @pool.with { |r| r.publish(channel, body) }
      end

      # Blocks on a dedicated connection (subscribe owns its socket). `timeout`
      # (seconds) raises ::Redis::TimeoutError after silence — pass it so tests
      # and shutdown don't hang forever. Yields (channel, message).
      def subscribe(*channels, timeout: nil)
        conn = Connection.client(url: @url || Connection::DEFAULT_URL)
        handler = lambda do |on|
          on.message { |channel, message| yield channel, message }
        end
        if timeout
          conn.subscribe_with_timeout(timeout, *channels, &handler)
        else
          conn.subscribe(*channels, &handler)
        end
      ensure
        conn&.close
      end
    end
  end
end

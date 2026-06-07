require "json"

module Shaolin
  module HTTP
    # Fixed-window rate limiter (issue #25), backed by any Shaolin::Store
    # (Redis in prod, Store::Memory in tests). Wire it via the middleware hook:
    #
    #   HTTP.register_provider!(middleware: [
    #     ->(app) { Shaolin::HTTP::RateLimit.new(app, store: Shaolin::Kernel["redis.store"],
    #                                            limit: 100, window: 60) }
    #   ])
    #
    # Past `limit` requests per `window` seconds for a key (default: client IP, or
    # an identity via a custom `key:`) it returns 429 with Retry-After. The window
    # key rotates by time bucket; `increment(ttl:)` expires old buckets.
    class RateLimit
      def initialize(app, store:, limit:, window: 60,
                     key: ->(env) { env["HTTP_X_FORWARDED_FOR"]&.split(",")&.first&.strip || env["REMOTE_ADDR"] || "anon" })
        @app = app
        @store = store
        @limit = limit
        @window = window
        @key = key
      end

      def call(env)
        id = @key.call(env)
        bucket = "ratelimit:#{id}:#{Time.now.to_i / @window}"
        count = @store.increment(bucket, ttl: @window * 2)

        return too_many if count > @limit

        status, headers, body = @app.call(env)
        headers["x-ratelimit-limit"] = @limit.to_s
        headers["x-ratelimit-remaining"] = [@limit - count, 0].max.to_s
        [status, headers, body]
      end

      private

      def too_many
        [429, { "content-type" => "application/json", "retry-after" => @window.to_s },
         [JSON.generate(error: { code: "rate_limited", message: "too many requests" })]]
      end
    end
  end
end

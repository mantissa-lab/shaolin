require "json"
require "shaolin/core"

module Shaolin
  module Redis
    # Redis-backed cache implementing the Shaolin::Cache port. Values are JSON
    # so primitives, arrays, and hashes round-trip; TTL is delegated to Redis
    # (SET ... EX), so expiry is shared across all processes — unlike the
    # in-memory adapter. Keys are namespaced to keep clear/scan scoped.
    class Cache
      include Shaolin::Cache

      def initialize(pool:, namespace: "cache")
        @pool = pool
        @namespace = namespace
      end

      def read(key, now: nil)
        raw = @pool.with { |r| r.get(namespaced(key)) }
        # symbolize_names matches the rest of shaolin (DTOs, params, Store) so a
        # cache HIT returns the same shape a MISS computed.
        raw.nil? ? nil : JSON.parse(raw, symbolize_names: true)
      end

      def write(key, value, ttl: nil)
        payload = JSON.generate(value)
        @pool.with do |r|
          ttl ? r.set(namespaced(key), payload, ex: ttl) : r.set(namespaced(key), payload)
        end
        value
      end

      def exist?(key, now: nil)
        @pool.with { |r| r.exists?(namespaced(key)) }
      end

      def delete(key)
        @pool.with { |r| r.del(namespaced(key)) }
      end

      def clear
        @pool.with do |r|
          keys = r.scan_each(match: "#{@namespace}:*").to_a
          r.del(*keys) unless keys.empty?
        end
      end

      private

      def namespaced(key) = "#{@namespace}:#{key}"
    end
  end
end

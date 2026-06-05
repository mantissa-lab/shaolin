require "json"
require "shaolin/core"

module Shaolin
  module Redis
    # Redis as a database: a namespaced key-value + hash store with JSON values.
    # Use it for read models, sessions, feature flags, counters, or LLM state
    # (conversation context, rate-limit windows, embeddings cache keys). Distinct
    # from Cache: Store is the source of truth (no implicit TTL), Cache is
    # disposable. Counters use native INCR (integers, not JSON).
    class Store
      include Shaolin::Store

      def initialize(pool:, namespace: "store")
        @pool = pool
        @namespace = namespace
      end

      # --- key/value (JSON) ---
      def set(key, value, ttl: nil)
        payload = JSON.generate(value)
        @pool.with do |r|
          ttl ? r.set(k(key), payload, ex: ttl) : r.set(k(key), payload)
        end
        value
      end

      def get(key)
        raw = @pool.with { |r| r.get(k(key)) }
        raw.nil? ? nil : JSON.parse(raw, symbolize_names: true)
      end

      def delete(key) = @pool.with { |r| r.del(k(key)) }
      def exists?(key) = @pool.with { |r| r.exists?(k(key)) }

      # --- counters (native integer) ---
      def increment(key, by: 1) = @pool.with { |r| r.incrby(k(key), by) }
      def decrement(key, by: 1) = @pool.with { |r| r.decrby(k(key), by) }

      # --- hashes (JSON field values) — a "row" with named fields ---
      def hset(key, field, value) = @pool.with { |r| r.hset(k(key), field, JSON.generate(value)) }

      def hget(key, field)
        raw = @pool.with { |r| r.hget(k(key), field) }
        raw.nil? ? nil : JSON.parse(raw, symbolize_names: true)
      end

      def hgetall(key)
        @pool.with { |r| r.hgetall(k(key)) }
             .each_with_object({}) { |(field, raw), out| out[field.to_sym] = JSON.parse(raw, symbolize_names: true) }
      end

      # --- iteration (namespaced, cursor-based — safe on large keyspaces) ---
      def keys(pattern = "*")
        @pool.with { |r| r.scan_each(match: k(pattern)).to_a }
             .map { |full| full.delete_prefix("#{@namespace}:") }
      end

      private

      def k(key) = "#{@namespace}:#{key}"
    end
  end
end

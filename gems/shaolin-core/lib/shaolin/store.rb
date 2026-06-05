require "json"

module Shaolin
  # The key-value/hash store port — "X as a database" (read models, sessions,
  # counters, LLM state). Domain code depends on this; Shaolin::Redis::Store binds
  # it to Redis, and Store::Memory is the in-process implementation for tests (so
  # you don't reach for a real Redis or abuse the Cache). Both JSON-round-trip
  # values, so keys come back as symbols consistently in both.
  module Store
    def set(_key, _value, ttl: nil) = raise NotImplementedError
    def get(_key) = raise NotImplementedError
    def delete(_key) = raise NotImplementedError
    def exists?(_key) = raise NotImplementedError
    def increment(_key, by: 1) = raise NotImplementedError
    def decrement(_key, by: 1) = raise NotImplementedError
    def hset(_key, _field, _value) = raise NotImplementedError
    def hget(_key, _field) = raise NotImplementedError
    def hgetall(_key) = raise NotImplementedError
    def keys(_pattern = "*") = raise NotImplementedError

    # Process-local store; mirrors Shaolin::Redis::Store semantics (JSON values,
    # symbol keys on read, native integer counters). For tests, not sharing.
    class Memory
      include Store

      def initialize
        @kv = {}
        @hashes = Hash.new { |h, k| h[k] = {} }
      end

      def set(key, value, ttl: nil)
        @kv[key.to_s] = JSON.generate(value)
        value
      end

      def get(key)
        raw = @kv[key.to_s]
        raw.nil? ? nil : JSON.parse(raw, symbolize_names: true)
      end

      def delete(key) = @kv.delete(key.to_s) ? 1 : 0
      def exists?(key) = @kv.key?(key.to_s) || @hashes.key?(key.to_s)

      def increment(key, by: 1) = (@kv[key.to_s] = ((@kv[key.to_s] || "0").to_i + by).to_s).to_i
      def decrement(key, by: 1) = increment(key, by: -by)

      def hset(key, field, value)
        @hashes[key.to_s][field.to_s] = JSON.generate(value)
        1
      end

      def hget(key, field)
        raw = @hashes[key.to_s][field.to_s]
        raw.nil? ? nil : JSON.parse(raw, symbolize_names: true)
      end

      def hgetall(key)
        @hashes[key.to_s].each_with_object({}) { |(f, raw), out| out[f.to_sym] = JSON.parse(raw, symbolize_names: true) }
      end

      def keys(pattern = "*")
        regex = Regexp.new("\\A#{Regexp.escape(pattern).gsub('\\*', '.*')}\\z")
        (@kv.keys + @hashes.keys).uniq.grep(regex)
      end
    end
  end
end

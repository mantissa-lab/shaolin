require "json"

module Shaolin
  module Redis
    # Consumes integration events from a Redis Stream via a consumer group
    # (XREADGROUP / XACK). Each group sees every message once; multiple consumers
    # in a group share the load and never double-process (Redis tracks pending
    # entries per consumer). Crashed consumers' un-acked entries are recoverable
    # with `reclaim` (XAUTOCLAIM). At-least-once → handlers must be idempotent.
    #
    # The app maps each yielded envelope to a Command on its own bus — the same
    # write path as HTTP.
    class StreamConsumer
      def initialize(pool:, stream: "shaolin:events", group:, consumer:, count: 10, block_ms: 2000)
        @pool = pool
        @stream = stream
        @group = group
        @consumer = consumer
        @count = count
        @block_ms = block_ms
        @running = false
      end

      # Idempotently create the group (reading only NEW messages from here on).
      def ensure_group!(start: "$")
        @pool.with { |r| r.xgroup(:create, @stream, @group, start, mkstream: true) }
      rescue ::Redis::CommandError => e
        raise unless e.message.include?("BUSYGROUP")
      end

      # One read → handle → ack cycle. Returns the number of entries processed.
      # Used by `run` and directly in tests (no infinite loop).
      def poll
        ensure_group!
        result = @pool.with { |r| r.xreadgroup(@group, @consumer, @stream, ">", count: @count, block: @block_ms) }
        return 0 if result.nil? || result.empty?

        entries = result[@stream] || []
        entries.each do |id, fields|
          yield parse(fields)
          @pool.with { |r| r.xack(@stream, @group, id) }
        end
        entries.size
      end

      # Loop poll until SIGTERM/INT (graceful: finishes the in-flight batch).
      def run(&block)
        ensure_group!
        @running = true
        %w[TERM INT].each { |sig| trap(sig) { @running = false } }
        poll(&block) while @running
      end

      # Reclaim entries pending (un-acked) longer than `idle_ms` from crashed
      # consumers, then handle + ack them. Returns the count reclaimed.
      def reclaim(idle_ms: 60_000)
        ensure_group!
        result = @pool.with { |r| r.xautoclaim(@stream, @group, @consumer, idle_ms, "0-0", count: @count) }
        entries = result["entries"] || []
        entries.each do |id, fields|
          yield parse(fields)
          @pool.with { |r| r.xack(@stream, @group, id) }
        end
        entries.size
      end

      private

      def parse(fields)
        JSON.parse(fields["body"], symbolize_names: true)
      end
    end
  end
end

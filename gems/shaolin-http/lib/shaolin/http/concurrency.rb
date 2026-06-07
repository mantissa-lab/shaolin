require "concurrent"
require "shaolin/core"

module Shaolin
  module HTTP
    # Admission control (issue #20): bound in-flight requests so a burst can't
    # oversubscribe the DB pool. Past the cap we LOAD-SHED — return 503 immediately
    # rather than queue behind a saturated pool (which would just time out). The
    # cap is opt-in (`SHAOLIN_WEB_CONCURRENCY`); set it ≈ DB_POOL. Also tracks the
    # in-flight gauge that /metrics reads, so you can size the cap from real data.
    class Concurrency
      OVERLOADED = [503,
                    { "content-type" => "application/json", "retry-after" => "1" },
                    [%({"error":{"code":"overloaded","message":"server at capacity"}})]].freeze

      attr_reader :max

      def initialize(app, max:)
        @app = app
        @max = max
        @semaphore = Concurrent::Semaphore.new(max)
        @in_flight = Concurrent::AtomicFixnum.new(0)
        Shaolin::Kernel.register("http.concurrency", self) # so Metrics can read it
      end

      def in_flight = @in_flight.value

      def call(env)
        return OVERLOADED.map(&:dup) unless @semaphore.try_acquire

        @in_flight.increment
        begin
          @app.call(env)
        ensure
          @in_flight.decrement
          @semaphore.release
        end
      end
    end
  end
end

require "async"

module Shaolin
  module Server
    # Per-request deadline for the async (Falcon) adapter (issue #21). A slow/hung
    # handler otherwise holds its fiber AND its checked-out DB connection forever,
    # starving the pool. Runs inside the request's Async task and uses a
    # cooperative `with_timeout` (interrupts at yield points — safe, unlike
    # Ruby's Timeout). On expiry it frees the fiber/connection and returns 503.
    # No-op when there's no current Async task (so it's inert under Puma).
    class Timeout
      EXPIRED = [503, { "content-type" => "application/json", "retry-after" => "1" },
                 [%({"error":{"code":"timeout","message":"request timed out"}})]].freeze

      def initialize(app, seconds)
        @app = app
        @seconds = seconds
      end

      def call(env)
        task = Async::Task.current?
        return @app.call(env) unless task && @seconds

        task.with_timeout(@seconds) { @app.call(env) }
      rescue Async::TimeoutError
        EXPIRED.map(&:dup)
      end
    end
  end
end

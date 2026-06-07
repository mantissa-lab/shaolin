module Shaolin
  # A small thread-safe circuit breaker for outbound calls (RabbitMQ/Redis/HTTP):
  # after `threshold` consecutive failures it OPENS and fast-fails for
  # `reset_timeout` seconds (so a brownout doesn't pile up doomed calls), then
  # HALF-OPENs to trial one through — success closes it, a failure re-opens it.
  # Wrap any call: `breaker.call { publisher.publish(ie) }`.
  class CircuitBreaker
    # Raised instead of calling the block while the circuit is open.
    class OpenError < Shaolin::Error; end

    def initialize(threshold: 5, reset_timeout: 30,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @threshold = threshold
      @reset_timeout = reset_timeout
      @clock = clock
      @mutex = Mutex.new
      @failures = 0
      @state = :closed
      @opened_at = nil
    end

    def call
      raise OpenError, "circuit open" unless allow?

      begin
        result = yield
        record_success
        result
      rescue StandardError
        record_failure
        raise
      end
    end

    def state = @mutex.synchronize { current_state }

    private

    def allow? = @mutex.synchronize { current_state != :open }

    # Promote open → half_open once the cooldown has elapsed.
    def current_state
      @state = :half_open if @state == :open && (@clock.call - @opened_at) >= @reset_timeout
      @state
    end

    def record_success
      @mutex.synchronize { @failures = 0; @state = :closed }
    end

    def record_failure
      @mutex.synchronize do
        @failures += 1
        if @failures >= @threshold
          @state = :open
          @opened_at = @clock.call
        end
      end
    end
  end
end

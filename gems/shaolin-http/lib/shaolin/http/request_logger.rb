require "securerandom"
require "shaolin/core"

module Shaolin
  module HTTP
    # Assigns/propagates a request id and emits one structured access-log record
    # per request through the unified Shaolin::Log (so it shares sinks + level with
    # everything else). The id is taken from an inbound `X-Request-Id` or generated,
    # put into the log CONTEXT for the duration of the request (so commands/events
    # logged downstream carry it), exposed in `env`, and echoed in the response.
    class RequestLogger
      REQUEST_ID_ENV = "shaolin.request_id".freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        request_id = env["HTTP_X_REQUEST_ID"] || SecureRandom.uuid
        env[REQUEST_ID_ENV] = request_id
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        Shaolin::Log.with(request_id: request_id) do
          status, headers, body = @app.call(env)
          headers["x-request-id"] = request_id
          log(env, status, started)
          [status, headers, body]
        rescue StandardError => e
          log(env, 500, started, error: e.message)
          raise
        ensure
          # values set by app middleware (auth identity, project_id, ...) must not
          # leak to the next request on a reused fiber/thread
          Shaolin::Context.clear
        end
      end

      private

      def log(env, status, started, error: nil)
        # ErrorBoundary (inner) stashes a handled exception here for the detail.
        error ||= env["shaolin.error"]&.message
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        level = status >= 500 ? :error : (status >= 400 ? :warn : :info)
        fields = { method: env["REQUEST_METHOD"], path: env["PATH_INFO"], status: status, duration_ms: duration_ms }
        fields[:error] = error if error
        Shaolin::Log.emit(level, "request", **fields)
      end
    end
  end
end

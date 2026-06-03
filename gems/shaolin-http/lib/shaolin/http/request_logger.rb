require "json"
require "securerandom"
require "time"

module Shaolin
  module HTTP
    # Assigns/propagates a request id and emits one structured (JSON) access log
    # line per request — the baseline for production observability and tracing.
    # The id is taken from an inbound `X-Request-Id` (so it threads through a
    # proxy / upstream service) or generated; it is exposed in `env` for handlers
    # and echoed back in the response header.
    #
    # Set SHAOLIN_LOG=off to silence (e.g. in tests). Inject `logger:` (any object
    # with `#puts`) to redirect.
    class RequestLogger
      REQUEST_ID_ENV = "shaolin.request_id".freeze

      def initialize(app, logger: $stdout, enabled: ENV["SHAOLIN_LOG"] != "off")
        @app = app
        @logger = logger
        @enabled = enabled
      end

      def call(env)
        request_id = env["HTTP_X_REQUEST_ID"] || SecureRandom.uuid
        env[REQUEST_ID_ENV] = request_id
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        status, headers, body = @app.call(env)
        headers["x-request-id"] = request_id
        log(env, status, started, request_id) if @enabled
        [status, headers, body]
      rescue StandardError => e
        log(env, 500, started, request_id, error: e.message) if @enabled
        raise
      end

      private

      def log(env, status, started, request_id, error: nil)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        line = {
          ts: Time.now.utc.iso8601(3),
          level: error ? "error" : "info",
          msg: "request",
          request_id: request_id,
          method: env["REQUEST_METHOD"],
          path: env["PATH_INFO"],
          status: status,
          duration_ms: duration_ms
        }
        line[:error] = error if error
        @logger.puts(JSON.generate(line))
      end
    end
  end
end

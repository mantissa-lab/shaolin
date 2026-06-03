require "json"

module Shaolin
  module HTTP
    # Top-level error boundary: any exception escaping a controller becomes a JSON
    # response in the standard `{ "error": { "code", "message" } }` contract,
    # instead of the server's default 500 (which may leak a stack trace).
    #
    # Known exceptions map to precise statuses — matched by class NAME so this gem
    # needn't depend on ruby_event_store. An optimistic-concurrency clash on an
    # aggregate (two writers) becomes a clean 409, not a 500. Unknown errors are
    # 500 with a generic message in production (full message only when
    # SHAOLIN_ENV != production); the exception is stashed in env for the logger.
    class ErrorBoundary
      STATUS_BY_ERROR = {
        "RubyEventStore::WrongExpectedEventVersion" => [409, "conflict"],
        "Shaolin::CQRS::UnregisteredCommand"        => [422, "unprocessable_command"]
      }.freeze

      ERROR_ENV = "shaolin.error".freeze

      def initialize(app, expose_details: ENV["SHAOLIN_ENV"] != "production")
        @app = app
        @expose = expose_details
      end

      def call(env)
        @app.call(env)
      rescue StandardError => e
        env[ERROR_ENV] = e
        status, code = STATUS_BY_ERROR[e.class.name] || [500, "internal_error"]
        message = status == 500 && !@expose ? "internal server error" : e.message
        [status, { "content-type" => "application/json" }, [JSON.generate(error: { code: code, message: message })]]
      end
    end
  end
end

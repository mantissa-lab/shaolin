require "async"
require "async/http/endpoint"
require "falcon"
require "protocol/rack"
require_relative "../timeout"

module Shaolin
  module Server
    module Adapters
      # Falcon adapter (default, async/fiber-per-request). `start` blocks running
      # the async reactor until stopped. A configured request_timeout wraps the
      # app in a cooperative per-request deadline (frees the fiber + DB connection
      # on a slow handler).
      class Falcon
        def start(rack_app, config)
          rack_app = Timeout.new(rack_app, config.request_timeout) if config.request_timeout
          app = Protocol::Rack::Adapter.new(rack_app)
          endpoint = Async::HTTP::Endpoint.parse("http://#{config.host}:#{config.port}")
          server = ::Falcon::Server.new(app, endpoint)

          @thread = Thread.current
          Async do |task|
            server.run
            task.children&.each(&:wait)
          end
        end

        # Stop from another thread (e.g. a SIGTERM handler): raise Async::Stop in
        # the reactor thread so the `Async{}` block unwinds and `start` returns.
        def stop(timeout: 10)
          @thread&.raise(Async::Stop)
        rescue StandardError
          nil
        end
      end
    end
  end
end

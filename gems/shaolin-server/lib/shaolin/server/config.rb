module Shaolin
  module Server
    # 12-factor server configuration from ENV. Falcon is the default (async-first);
    # Puma is opt-in via SHAOLIN_SERVER=puma.
    class Config
      attr_reader :host, :port, :adapter, :graceful_timeout, :request_timeout

      def initialize(env: ENV)
        @host = env.fetch("HOST", "0.0.0.0")
        @port = Integer(env.fetch("PORT", "8080"))
        @adapter = env.fetch("SHAOLIN_SERVER", "falcon").to_sym
        @graceful_timeout = Integer(env.fetch("SHAOLIN_GRACEFUL_TIMEOUT", "10"))
        # Per-request deadline (seconds); nil = off. Enforced on Falcon (async,
        # cooperative); on Puma use Rack::Timeout / Puma's own timeouts.
        rt = env["SHAOLIN_REQUEST_TIMEOUT"]
        @request_timeout = rt && Float(rt)
      end
    end
  end
end

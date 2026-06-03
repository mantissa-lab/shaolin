module Shaolin
  module Server
    # 12-factor server configuration from ENV. Falcon is the default (async-first);
    # Puma is opt-in via SHAOLIN_SERVER=puma.
    class Config
      attr_reader :host, :port, :adapter, :graceful_timeout

      def initialize(env: ENV)
        @host = env.fetch("HOST", "0.0.0.0")
        @port = Integer(env.fetch("PORT", "8080"))
        @adapter = env.fetch("SHAOLIN_SERVER", "falcon").to_sym
        @graceful_timeout = Integer(env.fetch("SHAOLIN_GRACEFUL_TIMEOUT", "10"))
      end
    end
  end
end

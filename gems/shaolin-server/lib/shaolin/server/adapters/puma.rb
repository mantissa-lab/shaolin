require "puma"
require "puma/server"

module Shaolin
  module Server
    module Adapters
      # Puma adapter (opt-in, thread-based). `start` blocks until stopped.
      class Puma
        def start(rack_app, config)
          @server = ::Puma::Server.new(rack_app)
          @server.add_tcp_listener(config.host, config.port)
          @server.run.join
        end

        def stop(timeout: 10)
          @server&.stop(true)
        end
      end
    end
  end
end

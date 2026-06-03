require_relative "config"
require_relative "adapters"

module Shaolin
  module Server
    # Serves a Rack app via the configured adapter and installs SIGTERM/SIGINT
    # traps for graceful shutdown (Cloud Run sends SIGTERM with a ~10s window).
    # `start` blocks; the signal handler triggers `stop` from a separate thread
    # (trap context is restricted).
    def self.run(rack_app, config: Config.new, adapter: nil)
      adapter ||= Adapters.build(config.adapter)
      install_traps(adapter, config)
      adapter.start(rack_app, config)
    end

    def self.install_traps(adapter, config)
      %w[TERM INT].each do |signal|
        Signal.trap(signal) { Thread.new { adapter.stop(timeout: config.graceful_timeout) } }
      end
    end
  end
end

require "shaolin/core"
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
      banner(config)
      install_traps(adapter, config)
      adapter.start(rack_app, config)
    end

    # One structured startup line (respects SHAOLIN_LOG), like worker/scheduler —
    # answers "did it start, where, which env, how is it bounded?" (#19).
    def self.banner(config)
      Shaolin::Log.emit("info", "server.started",
                        url: "http://#{config.host}:#{config.port}",
                        adapter: config.adapter,
                        env: ENV.fetch("SHAOLIN_ENV", "development"),
                        db_pool: Integer(ENV.fetch("DB_POOL", "5")),
                        web_concurrency: ENV["SHAOLIN_WEB_CONCURRENCY"] || "unbounded",
                        graceful_timeout: config.graceful_timeout)
    end

    def self.install_traps(adapter, config)
      %w[TERM INT].each do |signal|
        Signal.trap(signal) { Thread.new { adapter.stop(timeout: config.graceful_timeout) } }
      end
    end
  end
end

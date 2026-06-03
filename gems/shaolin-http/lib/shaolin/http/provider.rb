require "shaolin/core"
require_relative "router"

module Shaolin
  module HTTP
    # Registers the `:http` provider, which assembles the Rack app from module
    # controllers at boot and publishes it as `http.app`. Register AFTER `:cqrs`
    # (controllers resolve `cqrs.*` from the kernel when instantiated).
    #
    # `middleware:` is a list of builders (each a callable `->(app) { Mw.new(app) }`)
    # inserted just before the router — the place for app-level auth, rate
    # limiting, or CORS. They run inside the error boundary and request logger.
    def self.register_provider!(middleware: [])
      Shaolin.register_provider(:http) do
        start do
          containers = Shaolin::Kernel["kernel.containers"]
          Shaolin::Kernel.register("http.app", Router.build(containers, middleware: middleware))
        end
      end
    end
  end
end

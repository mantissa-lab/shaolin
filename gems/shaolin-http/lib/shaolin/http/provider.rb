require "shaolin/core"
require_relative "router"

module Shaolin
  module HTTP
    # Registers the `:http` provider, which assembles the Rack app from module
    # controllers at boot and publishes it as `http.app`. Register AFTER `:cqrs`
    # (controllers resolve `cqrs.*` from the kernel when instantiated).
    def self.register_provider!
      Shaolin.register_provider(:http) do
        start do
          containers = Shaolin::Kernel["kernel.containers"]
          Shaolin::Kernel.register("http.app", Router.build(containers))
        end
      end
    end
  end
end

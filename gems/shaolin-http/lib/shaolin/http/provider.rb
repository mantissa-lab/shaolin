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
    #
    # `swagger:` (opt-in) serves the OpenAPI 3.1 doc at GET /openapi.json and
    # interactive Swagger UI at GET /swagger — generated once at boot from the
    # controllers + DTOs. `modules_dir` is where to scan controllers for DTO
    # linking (default: <cwd>/app/modules). Keep it off in production unless you
    # mean to expose docs.
    def self.register_provider!(middleware: [], swagger: false, modules_dir: nil)
      Shaolin.register_provider(:http) do
        start do
          containers = Shaolin::Kernel["kernel.containers"]
          openapi = (OpenAPI.generate(containers, modules_dir || File.join(Dir.pwd, "app/modules")) if swagger)
          Shaolin::Kernel.register("http.app", Router.build(containers, middleware: middleware, openapi: openapi))
        end
      end
    end
  end
end

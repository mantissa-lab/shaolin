require "hanami/router"
require "json"
require "shaolin/core"
require_relative "request"
require_relative "errors"
require_relative "rewindable_input"
require_relative "request_logger"
require_relative "error_boundary"
require_relative "metrics"

module Shaolin
  module HTTP
    # Assembles one Rack app from every module's controllers. Each module
    # container's `controllers.*` components contribute their `route_set`;
    # path+verb collisions across modules fail fast at boot.
    #
    # Probes: GET /healthz (liveness, always 200) and /readyz (readiness — runs
    # Shaolin::Health checks, 503 if any dependency is down). GET /metrics is a
    # Prometheus exposition. The middleware stack (outer→inner) is:
    #   RequestLogger → ErrorBoundary → RewindableInput → [app middleware] → router
    # so every response is logged with a request id, every exception becomes the
    # JSON error contract, and oversized bodies are capped. `middleware:` lets an
    # app insert its own Rack middleware (auth, rate limiting, CORS) before the
    # router.
    module Router
      LIVENESS = ->(_env) { [200, { "content-type" => "application/json" }, ['{"status":"ok"}']] }

      def self.build(containers, middleware: [], openapi: nil)
        defs = collect_route_defs(containers)
        detect_conflicts!(defs)

        app = build_router(defs, openapi)
        middleware.reverse_each { |mw| app = mw.call(app) }
        app = RewindableInput.new(app)
        app = ErrorBoundary.new(app)
        RequestLogger.new(app)
      end

      def self.collect_route_defs(containers)
        defs = []
        containers.each do |module_name, container|
          container.keys.grep(/\Acontrollers\./).each do |key|
            controller = container[key]
            controller.class.route_set.each do |route|
              defs << route.merge(controller: controller, module: module_name)
            end
          end
        end
        defs
      end

      def self.detect_conflicts!(defs)
        seen = {}
        defs.each do |d|
          signature = [d[:method], d[:path]]
          if seen[signature]
            raise RouteConflictError,
                  "#{d[:method].to_s.upcase} #{d[:path]} defined by both '#{seen[signature]}' and '#{d[:module]}'"
          end
          seen[signature] = d[:module]
        end
      end

      def self.build_router(defs, openapi = nil)
        liveness = LIVENESS
        readiness = method(:readiness_response)
        metrics = method(:metrics_response)
        spec_json = (JSON.generate(openapi) if openapi)
        Hanami::Router.new do
          get("/healthz", to: liveness)
          get("/readyz",  to: readiness)
          get("/metrics", to: metrics)
          if spec_json
            get("/openapi.json", to: ->(_e) { [200, { "content-type" => "application/json" }, [spec_json]] })
            get("/swagger", to: ->(_e) { [200, { "content-type" => "text/html; charset=utf-8" }, [SWAGGER_HTML]] })
          end
          defs.each do |d|
            controller = d[:controller]
            action = d[:action]
            endpoint = ->(env) { controller.public_send(action, Request.new(env)) }
            public_send(d[:method], d[:path], to: endpoint)
          end
        end
      end

      # Swagger UI from the CDN, pointed at /openapi.json (no bundled assets).
      SWAGGER_HTML = <<~HTML.freeze
        <!doctype html><html><head><meta charset="utf-8"><title>API — Swagger UI</title>
        <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css"></head>
        <body><div id="swagger-ui"></div>
        <script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
        <script>window.onload = () => SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' });</script>
        </body></html>
      HTML

      def self.readiness_response(_env)
        ok, detail = Shaolin::Health.status
        body = JSON.generate(status: ok ? "ok" : "unavailable", checks: detail)
        [ok ? 200 : 503, { "content-type" => "application/json" }, [body]]
      end

      def self.metrics_response(_env)
        [200, { "content-type" => "text/plain; version=0.0.4" }, [Metrics.render]]
      end
    end
  end
end

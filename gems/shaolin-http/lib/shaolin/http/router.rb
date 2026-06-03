require "hanami/router"
require_relative "request"
require_relative "errors"
require_relative "rewindable_input"

module Shaolin
  module HTTP
    # Assembles one Rack app from every module's controllers. Each module
    # container's `controllers.*` components contribute their `route_set`;
    # path+verb collisions across modules fail fast at boot.
    module Router
      HEALTH = ->(_env) { [200, { "content-type" => "application/json" }, ['{"status":"ok"}']] }

      def self.build(containers)
        defs = collect_route_defs(containers)
        detect_conflicts!(defs)
        RewindableInput.new(build_router(defs))
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

      def self.build_router(defs)
        health = HEALTH
        Hanami::Router.new do
          get("/healthz", to: health)
          defs.each do |d|
            controller = d[:controller]
            action = d[:action]
            endpoint = ->(env) { controller.public_send(action, Request.new(env)) }
            public_send(d[:method], d[:path], to: endpoint)
          end
        end
      end
    end
  end
end

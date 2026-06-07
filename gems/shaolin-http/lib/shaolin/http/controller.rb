require "json"
require "shaolin/core"

module Shaolin
  module HTTP
    # Base controller. Declares routes and orchestrates: validate -> dispatch
    # (command/query bus) -> render. Translates dry-monads results into HTTP at
    # the single edge (`render_result`). Holds no request state — one instance is
    # reused; the action receives the Request.
    class Controller
      include Shaolin::Imports # `import("other.thing")` — validated cross-module access

      JSON_HEADERS = { "content-type" => "application/json" }.freeze

      # Collects route declarations inside `routes do ... end`.
      class RouteCollector
        attr_reader :routes

        def initialize
          @routes = []
        end

        # `response:` (optional) documents the response schema for OpenAPI — a DTO
        # class (→ 200) or a { status => DTO } hash. `auth:` (optional) names the
        # authenticator that guards this route (registered on the :http provider);
        # the framework runs it before the action and 401s on a nil identity.
        # Neither affects path matching.
        %i[get post put patch delete].each do |verb|
          define_method(verb) do |path, action, response: nil, auth: nil|
            @routes << { method: verb, path: path, action: action, response: response, auth: auth }
          end
        end
      end

      def self.routes(&block)
        collector = RouteCollector.new
        collector.instance_eval(&block)
        route_set.concat(collector.routes)
      end

      def self.route_set = @route_set ||= []

      # A default authenticator for every route in this controller (a per-route
      # `auth:` overrides it). `auth :admin` reads as the controller's auth plane.
      def self.default_auth(scheme = nil)
        @default_auth = scheme if scheme
        @default_auth
      end

      # Framework infra resolved lazily from the kernel (registered by :cqrs),
      # so controllers reach the buses without load-time DI wiring.
      def command_bus = Shaolin::Kernel["cqrs.command_bus"]
      def query_bus   = Shaolin::Kernel["cqrs.query_bus"]
      def event_store = Shaolin::Kernel["cqrs.event_store"]

      def json(data, status: 200)
        [status, JSON_HEADERS.dup, [JSON.generate(data)]]
      end

      def created(data, location: nil)
        headers = JSON_HEADERS.dup
        headers["location"] = location if location
        [201, headers, [JSON.generate(data)]]
      end

      def no_content
        [204, {}, []]
      end

      def not_found(message = "not found")
        error_response(404, "not_found", message)
      end

      def unprocessable(details)
        [422, JSON_HEADERS.dup, [JSON.generate(error: { code: "validation", details: details })]]
      end

      # Translate a dry-monads Result to an HTTP response.
      def render_result(result, location: nil)
        return render_failure(result.failure) if result.failure?

        value = result.respond_to?(:value!) ? result.value! : result.success
        payload = value.respond_to?(:to_h) ? value.to_h : { result: value }
        location ? created(payload, location: location) : json(payload)
      end

      private

      def render_failure(failure)
        code, detail = Array(failure)
        case code
        when :not_found then error_response(404, "not_found", detail)
        when :conflict  then error_response(409, "conflict", detail)
        else error_response(422, code.to_s, detail)
        end
      end

      def error_response(status, code, detail)
        [status, JSON_HEADERS.dup, [JSON.generate(error: { code: code, message: detail }.compact)]]
      end
    end
  end
end

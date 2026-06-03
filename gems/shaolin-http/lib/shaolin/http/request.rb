require "json"

module Shaolin
  module HTTP
    # Thin wrapper over the Rack env. `params` merges hanami-router path params
    # with a parsed JSON body (symbol keys). The raw body is read once and cached.
    class Request
      def initialize(env)
        @env = env
      end

      def params
        @params ||= router_params.merge(body_params)
      end

      def [](key) = params[key.to_sym]

      def headers
        @env.select { |k, _| k.start_with?("HTTP_") }
      end

      def body
        @body ||= (@env["rack.input"]&.read || "")
      end

      private

      def router_params
        (@env["router.params"] || {}).transform_keys(&:to_sym)
      end

      def body_params
        return {} if body.empty?

        JSON.parse(body, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end
    end
  end
end

require "json"
require "rack"

module Shaolin
  module HTTP
    # Thin wrapper over the Rack env. `params` merges hanami-router path params
    # with the parsed body — JSON, `multipart/form-data`, or
    # `application/x-www-form-urlencoded` (symbol keys). Uploaded files surface via
    # `#files`. The raw body is read once and cached.
    class Request
      def initialize(env)
        @env = env
      end

      # Read-only access to the raw Rack env — e.g. to read a value a middleware
      # wrote (`request.env["myapp.identity"]`). For a typed cross-cutting channel
      # prefer Shaolin::Context (set in middleware, read in the action).
      attr_reader :env

      def params
        @params ||= router_params.merge(body_params)
      end

      def [](key) = params[key.to_sym]

      def headers
        @env.select { |k, _| k.start_with?("HTTP_") }
      end

      # Request cookies as a symbol-keyed hash (parsed from the Cookie header).
      def cookies
        @cookies ||= Rack::Utils.parse_cookies(@env).transform_keys(&:to_sym)
      end

      def body
        @body ||= read_body
      end

      # Uploaded files from a multipart request: { field => { filename:, type:,
      # bytes:, tempfile: } }. Empty for non-multipart requests.
      def files
        form_parts unless defined?(@files)
        @files
      end

      private

      def read_body
        input = @env["rack.input"]
        return "" unless input

        input.rewind if input.respond_to?(:rewind)
        input.read || ""
      end

      def router_params
        (@env["router.params"] || {}).transform_keys(&:to_sym)
      end

      def body_params
        return form_fields if form_encoded?

        return {} if body.empty?

        JSON.parse(body, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      def form_encoded?
        ct = @env["CONTENT_TYPE"].to_s
        ct.start_with?("multipart/form-data", "application/x-www-form-urlencoded")
      end

      def form_fields
        form_parts
        @form_fields
      end

      # Parse the form once via Rack; split scalar fields from uploaded files.
      # Rack represents an upload as a Hash with a :tempfile — we expose its bytes
      # alongside the metadata. Input is rewindable (RewindableInput middleware).
      def form_parts
        @form_fields = {}
        @files = {}
        Rack::Request.new(@env).POST.each do |key, value|
          k = key.to_sym
          if value.is_a?(Hash) && value[:tempfile]
            @files[k] = { filename: value[:filename], type: value[:type],
                          tempfile: value[:tempfile], bytes: value[:tempfile].read }
          else
            @form_fields[k] = value
          end
        end
      rescue StandardError
        @form_fields ||= {}
        @files ||= {}
      end
    end
  end
end

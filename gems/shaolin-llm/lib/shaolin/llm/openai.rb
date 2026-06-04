require "net/http"
require "uri"
require "json"
require_relative "client"
require_relative "completion"

module Shaolin
  module LLM
    # OpenAI Chat Completions adapter (text + function/tool calling). Pure stdlib
    # Net::HTTP — no extra gem. The API key comes ONLY from the environment
    # (`OPENAI_API_KEY`), never hardcoded. Inject `transport:` (a ->(path, body){})
    # in tests to avoid the network. (Realtime/audio is a separate phase.)
    class OpenAI
      include Client

      def initialize(api_key: ENV["OPENAI_API_KEY"], model: "gpt-4.1",
                     base: "https://api.openai.com/v1", transport: nil)
        @api_key = api_key
        @model = model
        @base = base
        @transport = transport
      end

      def complete(messages:, tools: [], model: nil)
        body = { model: model || @model, messages: messages }
        unless tools.empty?
          body[:tools] = tools.map { |t| { type: "function", function: t } }
        end

        response = post("/chat/completions", body)
        message = response.dig("choices", 0, "message") || {}
        Completion.new(
          text: message["content"],
          tool_calls: parse_tool_calls(message["tool_calls"]),
          usage: response["usage"] || {}
        )
      end

      private

      def parse_tool_calls(raw)
        Array(raw).map do |tc|
          fn = tc["function"] || {}
          { name: fn["name"], arguments: parse_args(fn["arguments"]) }
        end
      end

      def parse_args(json)
        json.nil? || json.empty? ? {} : JSON.parse(json, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      def post(path, body)
        return @transport.call(path, body) if @transport

        raise "OPENAI_API_KEY not set" if @api_key.nil? || @api_key.empty?

        uri = URI("#{@base}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{@api_key}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        JSON.parse(http.request(req).body)
      end
    end
  end
end

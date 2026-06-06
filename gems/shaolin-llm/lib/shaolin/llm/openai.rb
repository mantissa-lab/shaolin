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

      # `reasoning_tag:` (opt-in) — when set (e.g. "think"), an inline
      # `<think>…</think>` block in the message content is lifted out into
      # `Completion#reasoning` and the remaining content returned as clean `text`.
      # Needed for models like Qwen that emit reasoning inline. Off by default, so
      # providers using a separate `reasoning_content`/`reasoning` field (mapped
      # automatically) and plain providers are unaffected.
      def initialize(api_key: ENV["OPENAI_API_KEY"], model: "gpt-4.1",
                     base: "https://api.openai.com/v1", transport: nil, reasoning_tag: nil)
        @api_key = api_key
        @model = model
        @base = base
        @transport = transport
        @reasoning_tag = reasoning_tag
      end

      def complete(messages:, tools: [], model: nil, response_format: nil)
        body = { model: model || @model, messages: messages }
        unless tools.empty?
          body[:tools] = tools.map { |t| { type: "function", function: t } }
        end
        body[:response_format] = response_format if response_format

        response = post("/chat/completions", body)
        message = response.dig("choices", 0, "message") || {}
        text, reasoning = extract_reasoning(message)
        Completion.new(
          text: text,
          reasoning: reasoning,
          tool_calls: parse_tool_calls(message["tool_calls"]),
          usage: response["usage"] || {},
          data: (parse_structured(text) if response_format)
        )
      end

      private

      # A structured-output request returns the JSON object as the message content;
      # parse it (symbol keys) onto Completion#data. nil if it isn't valid JSON.
      def parse_structured(content)
        return nil if content.nil? || content.empty?

        JSON.parse(content, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      # Returns [clean_text, reasoning]. A provider-supplied reasoning field wins
      # (content is already clean); otherwise, if a reasoning_tag is configured,
      # lift inline `<tag>…</tag>` block(s) out of the content.
      def extract_reasoning(message)
        content = message["content"]
        field = message["reasoning_content"] || message["reasoning"]
        return [content, field] if field && !field.empty?
        return [content, nil] unless @reasoning_tag && content

        strip_inline_reasoning(content)
      end

      def strip_inline_reasoning(content)
        tag = Regexp.escape(@reasoning_tag)
        reasoning = []
        clean = content.gsub(%r{<#{tag}>(.*?)</#{tag}>}m) do
          reasoning << Regexp.last_match(1).strip
          ""
        end
        [clean.strip, reasoning.empty? ? nil : reasoning.join("\n\n")]
      end

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

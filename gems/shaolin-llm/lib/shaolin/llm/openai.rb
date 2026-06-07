require "net/http"
require "uri"
require "json"
require "concurrent"
require "shaolin/core"
require_relative "client"
require_relative "completion"

module Shaolin
  module LLM
    # Raised when the LLM endpoint returns a non-2xx response (e.g. a gateway
    # proxy serving a 502/503 HTML page). Carries the status + a truncated body so
    # callers can rescue/inspect instead of crashing on a JSON parse of HTML.
    class HTTPError < Shaolin::Error
      attr_reader :status, :body

      def initialize(status, body)
        @status = status
        @body = body
        super("LLM HTTP #{status}: #{body}")
      end

      def server_error? = status >= 500
    end

    # OpenAI Chat Completions adapter (text + function/tool calling). Pure stdlib
    # Net::HTTP — no extra gem. The API key comes ONLY from the environment
    # (`OPENAI_API_KEY`), never hardcoded. Inject `transport:` (a ->(path, body){})
    # in tests to avoid the network. (Realtime/audio is a separate phase.)
    class OpenAI
      include Client

      # Transient failures worth retrying (alongside 5xx HTTPError): connect/read
      # timeouts and dropped sockets — exactly the intermittent gateway blips of a
      # reasoning-model proxy.
      RETRYABLE = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
                   Errno::ECONNRESET, EOFError, SocketError].freeze

      # `reasoning_tag:` (opt-in) — when set (e.g. "think"), an inline
      # `<think>…</think>` block in the message content is lifted out into
      # `Completion#reasoning` and the remaining content returned as clean `text`.
      # Needed for models like Qwen that emit reasoning inline. Off by default, so
      # providers using a separate `reasoning_content`/`reasoning` field (mapped
      # automatically) and plain providers are unaffected.
      # `read_timeout` defaults to a generous 600s because reasoning models (Qwen
      # `<think>`, o-series) routinely take well over Net::HTTP's 60s default on a
      # single reply — otherwise a slow completion raises Net::ReadTimeout and the
      # turn is lost. `open_timeout` guards connect. Tune both per deployment.
      # `max_retries` (default 2 → up to 3 attempts) retries ONLY transient failures
      # — 5xx responses, timeouts, dropped sockets — with `retry_backoff` waits
      # between attempts. 4xx (client errors) never retry. Set 0 to disable.
      # `default_params` are sampling params applied to every call (e.g.
      # `{ max_tokens: 4096 }`); a per-call `params:` overrides them.
      def initialize(api_key: ENV["OPENAI_API_KEY"], model: "gpt-4.1",
                     base: "https://api.openai.com/v1", transport: nil, reasoning_tag: nil,
                     open_timeout: 15, read_timeout: 600, max_retries: 2, retry_backoff: [0.5, 2.0],
                     default_params: {}, max_concurrency: nil, tts_async: nil)
        @api_key = api_key
        @model = model
        @base = base
        @transport = transport
        @reasoning_tag = reasoning_tag
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_retries = max_retries
        @retry_backoff = retry_backoff
        @default_params = default_params || {}
        # Bound in-flight calls against a capacity-limited provider (e.g. a shared
        # self-hosted model) so a worker pool can't oversubscribe it — complete()
        # blocks past the cap instead of every app hand-rolling a semaphore.
        @semaphore = max_concurrency && Concurrent::Semaphore.new(max_concurrency)
        # Opt-in for async/job-based TTS backends: { result_path: "/audio/result/{id}",
        # done: ->(res){...}, poll_interval:, max_wait: }. nil = sync /audio/speech.
        @tts_async = tts_async
      end

      def complete(messages:, tools: [], model: nil, response_format: nil, params: {})
        body = { model: model || @model, messages: messages }
        body.merge!(@default_params).merge!(params || {}) # sampling: max_tokens/temperature/...
        unless tools.empty?
          body[:tools] = tools.map { |t| { type: "function", function: t } }
        end
        body[:response_format] = response_format if response_format

        response = post("/chat/completions", body)
        choice = response.dig("choices", 0) || {}
        message = choice["message"] || {}
        text, reasoning = extract_reasoning(message)
        Completion.new(
          text: text,
          reasoning: reasoning,
          tool_calls: parse_tool_calls(message["tool_calls"]),
          usage: response["usage"] || {},
          data: (parse_structured(text) if response_format),
          finish_reason: choice["finish_reason"]
        )
      end

      # Text → audio bytes (TTS) via POST /audio/speech. Sync by default (the
      # endpoint returns the audio inline); when `tts_async:` is configured, a 202
      # job response is polled to completion behind this call. Shares the same
      # timeout/retry/HTTPError/concurrency layer as `complete`.
      def speak(text, voice: "alloy", format: "mp3", model: "tts-1")
        body = { model: model, input: text, voice: voice, response_format: format }
        res = audio_request(Net::HTTP::Post.new(URI("#{@base}/audio/speech")).tap do |r|
          r["Content-Type"] = "application/json"
          r.body = JSON.generate(body)
        end)
        return res.body unless res.code == "202" && @tts_async

        poll_tts(res)
      end

      # Audio bytes → text (STT) via multipart POST /audio/transcriptions.
      def transcribe(audio_bytes, language: nil, model: "whisper-1", filename: "audio.wav", content_type: "audio/wav")
        boundary = "----shaolin#{object_id}"
        fields = { model: model, language: language }.compact
        req = Net::HTTP::Post.new(URI("#{@base}/audio/transcriptions"))
        req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        req.body = multipart_body(boundary, fields, filename, content_type, audio_bytes)
        JSON.parse(audio_request(req).body)["text"]
      end

      private

      # Run a prepared request through the shared concurrency/retry/HTTPError layer,
      # returning the raw Net::HTTPResponse (no JSON parse — audio bodies are bytes).
      def audio_request(req)
        uri = req.uri
        with_concurrency do
          with_retries do
            req["Authorization"] = "Bearer #{@api_key}" if @api_key
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == "https")
            http.open_timeout = @open_timeout
            http.read_timeout = @read_timeout
            res = http.request(req)
            raise HTTPError.new(Integer(res.code), res.body.to_s[0, 500]) unless res.code.start_with?("2")

            res
          end
        end
      end

      # Poll an async TTS job to completion, returning the audio bytes.
      def poll_tts(submit_res)
        cfg = @tts_async
        id = (JSON.parse(submit_res.body) rescue {}).values_at("job_id", "id").compact.first
        path = cfg[:result_path].sub("{id}", id.to_s)
        interval = cfg[:poll_interval] || 1.0
        deadline = monotonic + (cfg[:max_wait] || 120)
        loop do
          res = audio_request(Net::HTTP::Get.new(URI("#{@base}#{path}")))
          return res.body if cfg[:done].call(res)
          raise HTTPError.new(202, "TTS job #{id} not ready after #{cfg[:max_wait] || 120}s") if monotonic > deadline

          sleep(interval)
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def multipart_body(boundary, fields, filename, content_type, bytes)
        body = +""
        fields.each do |name, value|
          body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
        end
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n" \
                "Content-Type: #{content_type}\r\n\r\n"
        body.b + bytes.to_s.b + "\r\n--#{boundary}--\r\n".b
      end

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
        with_concurrency do
          next @transport.call(path, body) if @transport

          raise "OPENAI_API_KEY not set" if @api_key.nil? || @api_key.empty?

          uri = URI("#{@base}#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          req = Net::HTTP::Post.new(uri)
          req["Authorization"] = "Bearer #{@api_key}"
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)

          with_retries { request_json(http, req) }
        end
      end

      # Block past the configured concurrency cap (no-op when unset). Retries
      # happen INSIDE the held permit, so a retry doesn't open an extra connection
      # beyond the cap — exactly the thundering-herd this prevents.
      def with_concurrency
        return yield unless @semaphore

        @semaphore.acquire
        begin
          yield
        ensure
          @semaphore.release
        end
      end

      # One request: non-2xx raises a typed HTTPError (carrying status + truncated
      # body) instead of blindly JSON-parsing an HTML gateway page.
      def request_json(http, req)
        res = http.request(req)
        raise HTTPError.new(Integer(res.code), res.body.to_s[0, 500]) unless res.code.start_with?("2")

        JSON.parse(res.body)
      end

      def with_retries
        attempt = 0
        begin
          yield
        rescue *RETRYABLE, HTTPError => e
          transient = e.is_a?(HTTPError) ? e.server_error? : true
          raise unless transient && attempt < @max_retries

          sleep(@retry_backoff[attempt] || @retry_backoff.last || 0)
          attempt += 1
          retry
        end
      end
    end
  end
end

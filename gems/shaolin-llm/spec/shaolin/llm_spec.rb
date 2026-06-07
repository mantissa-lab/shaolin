require "spec_helper"

RSpec.describe Shaolin::LLM do
  describe Shaolin::LLM::InMemory do
    it "returns scripted completions in order and records the calls" do
      llm = described_class.new(
        Shaolin::LLM::Completion.new(text: "first"),
        { text: "second", tool_calls: [{ name: "lookup", arguments: { id: "1" } }] }
      )

      a = llm.complete(messages: [{ role: "user", content: "hi" }])
      b = llm.complete(messages: [{ role: "user", content: "more" }], tools: [{ name: "lookup" }])

      expect(a.text).to eq("first")
      expect(b.text).to eq("second")
      expect(b.tool_used?("lookup")).to be(true)
      expect(llm.calls.size).to eq(2)
      expect(llm.calls.last[:tools]).to eq([{ name: "lookup" }])
    end

    it "carries reasoning on scripted completions (hash and Completion forms)" do
      llm = described_class.new(
        { text: "clean", reasoning: "scripted trace" },
        Shaolin::LLM::Completion.new(text: "y", reasoning: "obj trace")
      )
      expect(llm.complete(messages: []).reasoning).to eq("scripted trace")
      expect(llm.complete(messages: []).reasoning).to eq("obj trace")
    end

    it "raises when the script is exhausted" do
      llm = described_class.new
      expect { llm.complete(messages: []) }.to raise_error(/no scripted response/)
    end

    it "is a Shaolin::LLM::Client" do
      expect(described_class.new).to be_a(Shaolin::LLM::Client)
    end

    it "scripts speak/transcribe for network-free audio tests" do
      llm = described_class.new(speak: ["AUDIO"], transcribe: ["hello world"])
      expect(llm.speak("hi", voice: "alloy")).to eq("AUDIO")
      expect(llm.transcribe("WAV", language: "en")).to eq("hello world")
      expect(llm.calls.map { |c| c[:audio] }).to eq(%i[speak transcribe])
    end
  end

  describe Shaolin::LLM::OpenAI do
    it "builds the request and parses text + tool calls + usage (injected transport)" do
      seen = nil
      transport = lambda do |path, body|
        seen = { path: path, body: body }
        {
          "choices" => [{ "message" => {
            "content" => "hello",
            "tool_calls" => [{ "function" => { "name" => "lookup_account", "arguments" => '{"id":"a1"}' } }]
          } }],
          "usage" => { "prompt_tokens" => 10, "completion_tokens" => 3 }
        }
      end

      llm = described_class.new(api_key: "test", model: "gpt-4.1", transport: transport)
      result = llm.complete(messages: [{ role: "user", content: "hi" }], tools: [{ name: "lookup_account" }])

      expect(seen[:path]).to eq("/chat/completions")
      expect(seen[:body][:model]).to eq("gpt-4.1")
      expect(seen[:body][:tools]).to eq([{ type: "function", function: { name: "lookup_account" } }])
      expect(result.text).to eq("hello")
      expect(result.tool_calls).to eq([{ name: "lookup_account", arguments: { id: "a1" } }])
      expect(result.usage["completion_tokens"]).to eq(3)
    end

    it "maps a separate reasoning_content field into Completion#reasoning, content stays clean" do
      transport = lambda do |_path, _body|
        { "choices" => [{ "message" => { "content" => "Hey you 😊", "reasoning_content" => "he seems lonely" } }] }
      end
      result = described_class.new(api_key: "t", transport: transport).complete(messages: [])
      expect(result.text).to eq("Hey you 😊")
      expect(result.reasoning).to eq("he seems lonely")
      expect(result.reasoning?).to be(true)
    end

    it "lifts an inline <think> block out of content when reasoning_tag is set (Qwen)" do
      transport = lambda do |_path, _body|
        { "choices" => [{ "message" => { "content" => "<think>he seems lonely, warm up</think>Hey you 😊" } }] }
      end
      result = described_class.new(api_key: "t", transport: transport, reasoning_tag: "think").complete(messages: [])
      expect(result.text).to eq("Hey you 😊")
      expect(result.reasoning).to eq("he seems lonely, warm up")
    end

    it "leaves an inline <think> block untouched when reasoning_tag is NOT set (default)" do
      transport = lambda do |_path, _body|
        { "choices" => [{ "message" => { "content" => "<think>x</think>Hi" } }] }
      end
      result = described_class.new(api_key: "t", transport: transport).complete(messages: [])
      expect(result.text).to eq("<think>x</think>Hi")
      expect(result.reasoning).to be_nil
    end

    it "passes response_format through and parses structured output onto Completion#data" do
      seen = nil
      transport = lambda do |_path, body|
        seen = body
        { "choices" => [{ "message" => { "content" => '{"verdict":"unsafe","reason":"abuse"}' } }] }
      end
      rf = { type: "json_schema", json_schema: { name: "verdict" } }
      result = described_class.new(api_key: "t", transport: transport).complete(messages: [], response_format: rf)

      expect(seen[:response_format]).to eq(rf)
      expect(result.data).to eq(verdict: "unsafe", reason: "abuse")
      expect(result.data?).to be(true)
    end

    it "leaves data nil when no response_format is requested (default)" do
      transport = ->(_p, _b) { { "choices" => [{ "message" => { "content" => "{\"x\":1}" } }] } }
      result = described_class.new(api_key: "t", transport: transport).complete(messages: [])
      expect(result.data).to be_nil
    end

    it "applies open/read timeouts to the HTTP connection (generous default for slow reasoning models)" do
      fake = instance_double(Net::HTTP, use_ssl?: true)
      allow(fake).to receive(:use_ssl=)
      allow(fake).to receive(:request).and_return(instance_double(Net::HTTPResponse, code: "200", body: '{"choices":[{"message":{"content":"ok"}}]}'))
      allow(Net::HTTP).to receive(:new).and_return(fake)

      # default: 15s connect / 600s read (a single Qwen <think> reply blows past Net::HTTP's 60s default)
      expect(fake).to receive(:open_timeout=).with(15)
      expect(fake).to receive(:read_timeout=).with(600)
      described_class.new(api_key: "t").complete(messages: [])
    end

    it "lets the read/open timeouts be configured" do
      fake = instance_double(Net::HTTP, use_ssl?: true)
      allow(fake).to receive(:use_ssl=)
      allow(fake).to receive(:request).and_return(instance_double(Net::HTTPResponse, code: "200", body: "{}"))
      allow(Net::HTTP).to receive(:new).and_return(fake)

      expect(fake).to receive(:open_timeout=).with(5)
      expect(fake).to receive(:read_timeout=).with(240)
      described_class.new(api_key: "t", open_timeout: 5, read_timeout: 240).complete(messages: [])
    end

    # A stubbed Net::HTTP whose #request returns the given responses in order.
    def stub_http(*responses)
      fake = instance_double(Net::HTTP, use_ssl?: true)
      allow(fake).to receive(:use_ssl=)
      allow(fake).to receive(:open_timeout=)
      allow(fake).to receive(:read_timeout=)
      allow(fake).to receive(:request).and_return(*responses)
      allow(Net::HTTP).to receive(:new).and_return(fake)
      fake
    end

    def res(code, body) = instance_double(Net::HTTPResponse, code: code, body: body)

    it "raises a typed HTTPError on a non-2xx response instead of JSON-parsing HTML" do
      stub_http(res("502", "<!DOCTYPE html><html>bad gateway</html>"))
      expect { described_class.new(api_key: "t", max_retries: 0).complete(messages: []) }
        .to raise_error(Shaolin::LLM::HTTPError) { |e| expect(e.status).to eq(502); expect(e.body).to include("bad gateway") }
    end

    it "retries a transient 5xx and then succeeds" do
      stub_http(res("503", "<html>"), res("200", '{"choices":[{"message":{"content":"ok"}}]}'))
      result = described_class.new(api_key: "t", max_retries: 2, retry_backoff: [0, 0]).complete(messages: [])
      expect(result.text).to eq("ok")
    end

    it "does NOT retry a 4xx client error" do
      fake = stub_http(res("400", "bad request"))
      expect(fake).to receive(:request).once.and_return(res("400", "bad request"))
      expect { described_class.new(api_key: "t", max_retries: 2, retry_backoff: [0, 0]).complete(messages: []) }
        .to raise_error(Shaolin::LLM::HTTPError) { |e| expect(e.status).to eq(400) }
    end

    it "merges default_params and per-call params into the body (per-call wins)" do
      seen = nil
      t = lambda do |_path, body|
        seen = body
        { "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }] }
      end
      llm = described_class.new(api_key: "t", transport: t, default_params: { max_tokens: 100, temperature: 0.2 })
      llm.complete(messages: [], params: { temperature: 0.9 })

      expect(seen[:max_tokens]).to eq(100)   # adapter default
      expect(seen[:temperature]).to eq(0.9)  # per-call override
    end

    it "surfaces finish_reason on the Completion (truncated? when cut at length)" do
      t = ->(_p, _b) { { "choices" => [{ "message" => { "content" => "" }, "finish_reason" => "length" }] } }
      result = described_class.new(api_key: "t", transport: t).complete(messages: [])
      expect(result.finish_reason).to eq("length")
      expect(result.truncated?).to be(true)
    end

    it "bounds in-flight calls to max_concurrency" do
      active = Concurrent::AtomicFixnum.new(0)
      peak = Concurrent::AtomicFixnum.new(0)
      transport = lambda do |_p, _b|
        n = active.increment
        peak.update { |v| [v, n].max }
        sleep 0.05
        active.decrement
        { "choices" => [{ "message" => { "content" => "ok" } }] }
      end
      llm = described_class.new(api_key: "t", transport: transport, max_concurrency: 1)

      Array.new(4) { Thread.new { llm.complete(messages: []) } }.each(&:join)
      expect(peak.value).to eq(1) # never more than 1 concurrent call past the cap
    end

    it "speak: POSTs /audio/speech and returns the audio bytes (sync)" do
      stub_http(res("200", "AUDIOBYTES"))
      expect(described_class.new(api_key: "t").speak("hello", voice: "alloy")).to eq("AUDIOBYTES")
    end

    it "transcribe: multipart POST /audio/transcriptions and returns the text" do
      stub_http(res("200", '{"text":"hi there"}'))
      expect(described_class.new(api_key: "t").transcribe("WAVBYTES", language: "en")).to eq("hi there")
    end

    it "speak: async — submits a job, polls the result, returns bytes when ready" do
      stub_http(res("202", '{"job_id":"j1"}'), res("202", '{"status":"pending"}'), res("200", "WAVBYTES"))
      llm = described_class.new(api_key: "t", tts_async: {
        result_path: "/audio/result/{id}", done: ->(r) { r.code == "200" }, poll_interval: 0, max_wait: 5
      })
      expect(llm.speak("hi")).to eq("WAVBYTES")
    end

    it "completes against the live API when OPENAI_API_KEY is set", :live do
      skip "set OPENAI_API_KEY to run the live OpenAI test" unless ENV["OPENAI_API_KEY"]

      result = described_class.new.complete(messages: [{ role: "user", content: "Reply with the word OK." }])
      expect(result.text).to be_a(String)
    end
  end
end

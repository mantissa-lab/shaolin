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

    it "completes against the live API when OPENAI_API_KEY is set", :live do
      skip "set OPENAI_API_KEY to run the live OpenAI test" unless ENV["OPENAI_API_KEY"]

      result = described_class.new.complete(messages: [{ role: "user", content: "Reply with the word OK." }])
      expect(result.text).to be_a(String)
    end
  end
end

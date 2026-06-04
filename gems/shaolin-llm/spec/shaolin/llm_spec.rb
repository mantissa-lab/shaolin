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

    it "completes against the live API when OPENAI_API_KEY is set", :live do
      skip "set OPENAI_API_KEY to run the live OpenAI test" unless ENV["OPENAI_API_KEY"]

      result = described_class.new.complete(messages: [{ role: "user", content: "Reply with the word OK." }])
      expect(result.text).to be_a(String)
    end
  end
end

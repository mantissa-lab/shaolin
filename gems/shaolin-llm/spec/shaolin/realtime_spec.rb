require "spec_helper"

RSpec.describe Shaolin::LLM::Realtime do
  Event = Shaolin::LLM::Realtime::Event

  describe Shaolin::LLM::Realtime::Audio do
    it "base64 round-trips PCM bytes" do
      bytes = "\x00\x01\x02\x03".b
      expect(described_class.decode(described_class.encode(bytes))).to eq(bytes)
    end

    it "exposes the default realtime PCM format" do
      expect(described_class::FORMAT).to include(encoding: "pcm16", sample_rate: 24_000)
    end
  end

  describe "a realtime session (InMemory adapter)" do
    it "drives a full voice turn: send audio -> transcript + tool_call -> tool_result -> turn_completed" do
      client = described_class::InMemory.new
      client.script_turn([
        Event.new(:transcript_delta, text: "Let me look that up.", role: "assistant"),
        Event.new(:tool_call, id: "c1", name: "lookup_account", arguments: { id: "a1" })
      ])
      client.script_turn([
        Event.new(:transcript_delta, text: "Your balance is $5.", role: "assistant"),
        Event.new(:turn_completed, transcript: "Your balance is $5.")
      ])

      received = []
      session = client.connect(model: "stub", tools: [{ name: "lookup_account" }])
      session.on_event { |e| received << e }

      session.send_audio("PCM_FROM_MIC")
      session.commit # session_started + turn 1

      # the app handles the tool call (in a real app: dispatch a command), then replies
      tool_call = received.find { |e| e.type == :tool_call }
      expect(tool_call[:name]).to eq("lookup_account")
      session.tool_result(tool_call[:id], "balance:$5")
      session.commit # turn 2

      session.close

      expect(received.map(&:type)).to eq(%i[session_started transcript_delta tool_call transcript_delta turn_completed session_closed])
      expect(session.sent_audio).to eq(["PCM_FROM_MIC"])
      expect(session.tool_results).to eq([["c1", "balance:$5"]])
    end
  end

  describe Shaolin::LLM::Realtime::OpenAI do
    # Fake WebSocket transport — records sent client events, injects server events.
    let(:transport) do
      Class.new do
        attr_reader :sent
        def initialize = (@sent = [])
        def send(msg) = (@sent << msg)
        def on_message(&b) = (@on = b)
        def feed(raw) = @on.call(raw)
        def close = (@sent << { type: "close" })
      end.new
    end

    it "translates OpenAI wire events to normalized events" do
      t = described_class
      expect(t.translate({ "type" => "session.created" }).type).to eq(:session_started)
      expect(t.translate({ "type" => "response.audio_transcript.delta", "delta" => "hi" })[:text]).to eq("hi")
      call = t.translate({ "type" => "response.function_call_arguments.done", "call_id" => "c1",
                           "name" => "lookup", "arguments" => '{"id":"a1"}' })
      expect([call.type, call[:id], call[:name], call[:arguments]]).to eq([:tool_call, "c1", "lookup", { id: "a1" }])
      expect(t.translate({ "type" => "response.done" }).type).to eq(:turn_completed)
      expect(t.translate({ "type" => "rate_limits.updated" })).to be_nil # ignored
    end

    it "maps session writes to OpenAI client events and incoming events upstream" do
      session = described_class::Session.new(transport, tools: [{ name: "lookup" }])
      received = []
      session.on_event { |e| received << e }

      session.send_audio("PCM")
      session.commit
      session.tool_result("c1", "balance:$5")
      transport.feed("type" => "response.audio_transcript.delta", "delta" => "Hello")

      types = transport.sent.map { |m| m[:type] }
      expect(types).to include("session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
                               "response.create", "conversation.item.create")
      expect(transport.sent.find { |m| m[:type] == "input_audio_buffer.append" }[:audio]).to eq(Shaolin::LLM::Realtime::Audio.encode("PCM"))
      expect(received.map(&:type)).to eq([:transcript_delta])
    end
  end

  describe ".register_provider!" do
    it "registers a realtime client in the kernel" do
      Shaolin::Provider.reset!
      Shaolin::Kernel.reset!
      client = described_class::InMemory.new
      described_class.register_provider!(client: client)
      Shaolin::Provider.start_all
      expect(Shaolin::Kernel["realtime.client"]).to be(client)
    end
  end
end

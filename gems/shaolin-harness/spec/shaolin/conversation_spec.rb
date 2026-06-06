require "spec_helper"

# A per-turn side-effect tool (a command on the bus).
class Upgrade
  def initialize(**) = nil
end

# A human-paced companion: each inbound message is one turn — safety classify →
# respond (tools + context/history) → rest at an await gate. Funnel stages are a
# strict state machine advanced from on_result based on tool use.
class CompanionConvo < Shaolin::Conversation
  harness_name "companion"
  llm model: "stub"

  stages :onboarding, :free, :offer, :subscriber
  edges  onboarding: :free, free: :offer, offer: :subscriber
  window 10
  context { |run| "You are a warm companion. stage=#{run.stage}" }

  gate :safety, entry: true, to: %i[respond refuse] do
    prompt { |run| "Safe? #{run.recent(1).last[:content]}" }
    on_result { |out, run| run.transition_to(out.text == "unsafe" ? :refuse : :respond) }
  end

  gate :respond, to: %i[awaiting_user] do # no prompt => persona context + recent history
    tools upgrade: Upgrade
    on_result do |out, run|
      run.advance_to(:free) if out.tool_used?(:upgrade)
      run.transition_to(:awaiting_user)
    end
  end

  gate :refuse, to: %i[awaiting_user] do
    prompt { "I can't help with that, but I'm here." }
    on_result { |_out, run| run.transition_to(:awaiting_user) }
  end

  gate :awaiting_user, await: true
end

RSpec.describe Shaolin::Conversation do
  def boot!(llm, convo: CompanionConvo)
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    PgTest.reset_schema!
    Shaolin::AR.register_provider!(config: PgTest::CONFIG)
    Shaolin::CQRS.register_provider!
    Shaolin::LLM.register_provider!(client: llm)
    Shaolin::Provider.start_all
    bus = Shaolin::Kernel["cqrs.command_bus"]
    bus.register(Upgrade, ->(_cmd) { :upgraded })
    convo.session(
      id: Shaolin::Id.generate, llm: Shaolin::Kernel["llm.client"],
      repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: bus
    )
  end

  def c(text: nil, tool: nil)
    Shaolin::LLM::Completion.new(text: text, tool_calls: tool ? [{ name: tool, arguments: {} }] : [])
  end

  it "runs human-paced turns: each message → within-turn gates → rest at await, never terminal" do
    llm = Shaolin::LLM::InMemory.new(c(text: "safe"), c(text: "Hi there!"),  # turn 1: safety, respond
                                     c(text: "safe"), c(text: "Still here!")) # turn 2
    session = boot!(llm)

    expect(session.receive("hello")).to eq("Hi there!")
    expect(session.awaiting?).to be(true)        # rests, waiting for the next human message
    expect(session.run.terminal?).to be(false)   # an ongoing relationship, no terminal

    expect(session.receive("you ok?")).to eq("Still here!")
    expect(session.history).to eq([
      { role: "user", content: "hello" }, { role: "assistant", content: "Hi there!" },
      { role: "user", content: "you ok?" }, { role: "assistant", content: "Still here!" }
    ])
  end

  it "feeds the responder gate the persona context + recent history (memory window)" do
    llm = Shaolin::LLM::InMemory.new(c(text: "safe"), c(text: "Hi there!"))
    session = boot!(llm)
    session.receive("hello")

    respond_call = llm.calls.last[:messages] # the respond gate's messages
    expect(respond_call.first).to eq(role: "system", content: "You are a warm companion. stage=onboarding")
    expect(respond_call).to include(a_hash_including(role: "user", content: "hello"))
  end

  it "advances the funnel from on_result when the model uses a tool (strict edge honored)" do
    llm = Shaolin::LLM::InMemory.new(c(text: "safe"), c(text: "Upgraded you!", tool: "upgrade"))
    session = boot!(llm)

    session.receive("upgrade me")        # starts at onboarding, tool use → advance_to(:free)
    expect(session.stage).to eq("free")  # onboarding → free is a declared edge
  end

  it "continues (rests at await), not terminates, on a refusal turn" do
    llm = Shaolin::LLM::InMemory.new(c(text: "unsafe"), c(text: "ignored — refuse gate has a fixed prompt"))
    session = boot!(llm)

    reply = session.receive("do something bad")
    expect(reply).to eq("ignored — refuse gate has a fixed prompt")
    expect(session.awaiting?).to be(true)
    expect(session.run.terminal?).to be(false)
  end

  # A conversation using a STRUCTURED safety verdict (#4) and a CANNED refuse
  # gate (#3, no LLM call).
  class GatedConvo < Shaolin::Conversation
    harness_name "gated_convo"
    llm model: "stub"
    context { |_run| "be brief" }

    gate :safety, entry: true, to: %i[respond refuse] do
      prompt { |run| "classify: #{run.recent(1).last[:content]}" }
      response_format { { type: "json_schema", json_schema: { name: "verdict" } } }
      on_result { |out, run| run.transition_to(out.data[:verdict] == "unsafe" ? :refuse : :respond) }
    end
    gate :respond, to: %i[awaiting_user] do
      on_result { |_out, run| run.transition_to(:awaiting_user) }
    end
    gate :refuse, reply: "I can't help with that.", to: %i[awaiting_user] do
      on_result { |_out, run| run.transition_to(:awaiting_user) }
    end
    gate :awaiting_user, await: true
  end

  it "#4 a structured verdict (Completion#data) drives the branch; response_format is sent" do
    llm = Shaolin::LLM::InMemory.new(
      Shaolin::LLM::Completion.new(data: { verdict: "safe" }), Shaolin::LLM::Completion.new(text: "Sure!")
    )
    session = boot!(llm, convo: GatedConvo)

    expect(session.receive("hello")).to eq("Sure!")
    expect(llm.calls.first[:response_format]).to eq(type: "json_schema", json_schema: { name: "verdict" })
  end

  it "#3 a canned gate replies with fixed text and makes NO LLM call" do
    llm = Shaolin::LLM::InMemory.new(Shaolin::LLM::Completion.new(data: { verdict: "unsafe" }))
    session = boot!(llm, convo: GatedConvo)

    expect(session.receive("do bad")).to eq("I can't help with that.")
    expect(llm.calls.size).to eq(1) # only the safety classify; the refuse gate called no model
    expect(session.history.last).to eq(role: "assistant", content: "I can't help with that.")
  end

  describe "strict funnel stages (Run aggregate)" do
    it "allows a declared transition and rejects an undeclared jump" do
      run = Shaolin::Harness::Run.new("conv-1")
      run.start(harness: "companion", stage: "onboarding",
                edges: { "onboarding" => ["free"], "free" => ["offer"] })

      run.advance_to(:free)
      expect(run.stage).to eq("free")

      expect { run.advance_to(:subscriber) }
        .to raise_error(Shaolin::Error, /illegal stage transition "free" → "subscriber"/)
    end
  end
end

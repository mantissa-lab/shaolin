require "spec_helper"

# A tool, dispatched on the command bus when the model calls it.
class LookupAccount
  attr_reader :id
  def initialize(id:) = (@id = id)
end

# A 3-gate harness: classify -> (respond | reject). classify calls a tool.
class TriageHarness < Shaolin::Harness
  harness_name "triage"
  llm model: "stub"

  gate :classify, entry: true do
    prompt { |run| "Classify: #{run.input[:text]}" }
    tools lookup: LookupAccount
    on_result { |out, run| run.transition_to(out.tool_used?(:lookup) ? :respond : :reject) }
  end

  gate :respond, terminal: true do
    prompt { |run| "Answer using #{run.tool_results.last[:result]}" }
    on_result { |out, run| run.complete(answer: out.text, account: run.tool_results.last[:result]) }
  end

  gate :reject, terminal: true do
    prompt { "n/a" }
    on_result { |_out, run| run.complete(answer: "rejected") }
  end
end

RSpec.describe Shaolin::Harness do
  let(:llm) do
    Shaolin::LLM::InMemory.new(
      Shaolin::LLM::Completion.new(tool_calls: [{ name: "lookup", arguments: { id: "a1" } }]), # classify
      Shaolin::LLM::Completion.new(text: "Here is your balance.")                              # respond
    )
  end

  def boot!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    PgTest.reset_schema!
    Shaolin::AR.register_provider!(config: PgTest::CONFIG)
    Shaolin::CQRS.register_provider!
    Shaolin::LLM.register_provider!(client: llm)
    Shaolin::Provider.start_all

    bus = Shaolin::Kernel["cqrs.command_bus"]
    bus.register(LookupAccount, ->(cmd) { "balance:#{cmd.id}" })
    Shaolin::Harness::Runner.new(
      harness: TriageHarness, llm: Shaolin::Kernel["llm.client"],
      repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: bus
    )
  end

  describe ".describe (machine-readable map)" do
    it "lists gates, entry/terminal, tools, and the model" do
      map = TriageHarness.describe
      expect(map[:name]).to eq("triage")
      expect(map[:model]).to eq("stub")
      classify = map[:gates].find { |g| g[:name] == "classify" }
      expect(classify).to include(entry: true, terminal: false, tools: ["lookup"])
    end
  end

  it "#1 runs synchronously: gate -> prompt -> llm -> tool(command) -> transition -> complete" do
    runner = boot!
    run = runner.run_to_completion(input: { text: "where is my money" })

    expect(run.completed?).to be(true)
    expect(run.current_gate).to eq("respond")
    expect(run.output).to eq(answer: "Here is your balance.", account: "balance:a1")
    # the tool ran as a command on the bus, result fed the next gate
    expect(run.tool_results).to eq([{ name: "lookup", result: "balance:a1" }])
  end

  it "#2 durable: a fresh runner resumes mid-run from the persisted event stream (no re-work)" do
    runner = boot!
    id = runner.start(input: { text: "help" })
    runner.advance(id) # classify step persisted; now at :respond

    expect(runner.load(id).current_gate).to eq("respond")
    expect(llm.calls.size).to eq(1)

    # "crash" → a brand-new Runner (state lives in the event store, not the runner)
    resumed = Shaolin::Harness::Runner.new(
      harness: TriageHarness, llm: Shaolin::Kernel["llm.client"],
      repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: Shaolin::Kernel["cqrs.command_bus"]
    )
    resumed.advance(id) until resumed.load(id).terminal?

    run = resumed.load(id)
    expect(run.completed?).to be(true)
    expect(run.output[:answer]).to eq("Here is your balance.")
    expect(llm.calls.size).to eq(2) # classify once + respond once — classify NOT redone
  end

  it "#6 replay is deterministic: reconstructing the run yields the same state" do
    runner = boot!
    id = Shaolin::Id.generate
    runner.run_to_completion(input: { text: "x" }, id: id)

    a = runner.load(id)
    b = runner.load(id)
    expect(a.output).to eq(b.output)
    expect(a.current_gate).to eq(b.current_gate)
    expect(b.completed?).to be(true)
  end
end

# A runnable LLM-harness demo on the InMemory stub — deterministic, no network,
# no API key. Proves: gate -> prompt -> llm -> tool(command) -> transition ->
# complete, event-sourced, in both sync and durable (resume) modes.
#
#   createdb -h /tmp -p 5433 -U postgres shaolin_harness_example
#   ruby examples/harness/verify.rb
require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/jobs"
require "shaolin/llm"
require "shaolin/harness"

DB = {
  adapter: "postgresql", database: ENV.fetch("DB_NAME", "shaolin_harness_example"),
  username: ENV.fetch("DB_USER", "postgres"), host: ENV.fetch("DB_HOST", "/tmp"),
  port: Integer(ENV.fetch("DB_PORT", "5433"))
}.freeze

# A tool — a plain command dispatched on the bus when the model calls it.
class LookupAccount
  attr_reader :id
  def initialize(id:) = (@id = id)
end

class SupportTriage < Shaolin::Harness
  harness_name "support_triage"
  llm model: "stub"

  gate :classify, entry: true do
    prompt { |run| "Classify and look up the customer for: #{run.input[:text]}" }
    tools  lookup: LookupAccount
    on_result { |out, run| run.transition_to(out.tool_used?(:lookup) ? :respond : :reject) }
  end

  gate :respond, terminal: true do
    prompt { |run| "Draft a reply using account #{run.tool_results.last[:result]}" }
    on_result { |out, run| run.complete(answer: out.text, account: run.tool_results.last[:result]) }
  end

  gate :reject, terminal: true do
    prompt { "n/a" }
    on_result { |_out, run| run.complete(answer: "rejected") }
  end
end

# Scripted LLM (deterministic): classify asks for the tool, respond drafts text.
llm = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(tool_calls: [{ name: "lookup", arguments: { id: "cust-42" } }]),
  Shaolin::LLM::Completion.new(text: "Hi! Your account is in good standing.")
)

Shaolin::AR.register_provider!(config: DB)
Shaolin::CQRS.register_provider!
Shaolin::Jobs.register_provider!
Shaolin::LLM.register_provider!(client: llm)
Shaolin::Harness.register_durable_provider! # subscribe GateEntered -> outbox (worker drive)
Shaolin::Provider.start_all

bus = Shaolin::Kernel["cqrs.command_bus"]
bus.register(LookupAccount, ->(cmd) { "acct(#{cmd.id})=premium" })

runner = Shaolin::Harness::Runner.new(
  harness: SupportTriage, llm: Shaolin::Kernel["llm.client"],
  repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: bus
)

puts "== gates =="
SupportTriage.describe[:gates].each { |g| puts "  #{g[:name]}#{' (entry)' if g[:entry]}#{' (terminal)' if g[:terminal]} tools=#{g[:tools]}" }

puts "\n== SYNC run =="
run = runner.run_to_completion(input: { text: "where is my money?" })
puts "  final gate: #{run.current_gate}, status: #{run.status}"
puts "  tool calls: #{run.tool_results.inspect}"
puts "  output:     #{run.output.inspect}"
raise "expected completion" unless run.completed?
raise "tool didn't run via the bus" unless run.tool_results == [{ name: "lookup", result: "acct(cust-42)=premium" }]
raise "wrong output" unless run.output == { answer: "Hi! Your account is in good standing.", account: "acct(cust-42)=premium" }

puts "\n== DURABLE resume (fresh runner continues from the event stream) =="
llm2 = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(tool_calls: [{ name: "lookup", arguments: { id: "cust-7" } }]),
  Shaolin::LLM::Completion.new(text: "Resumed answer.")
)
Shaolin::Kernel.register("llm.client", llm2)
r1 = Shaolin::Harness::Runner.new(harness: SupportTriage, llm: llm2, repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: bus)
id = r1.start(input: { text: "resume me" })
r1.advance(id) # classify persisted; now at :respond
puts "  after 1 advance: gate=#{r1.load(id).current_gate}, llm calls=#{llm2.calls.size}"

r2 = Shaolin::Harness::Runner.new(harness: SupportTriage, llm: llm2, repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: bus)
r2.advance(id) until r2.load(id).terminal?
done = r2.load(id)
puts "  resumed: status=#{done.status}, output=#{done.output.inspect}, total llm calls=#{llm2.calls.size}"
raise "resume failed" unless done.completed? && llm2.calls.size == 2 # classify not redone

puts "\n== WORKER-DRIVEN (the outbox loop — what `shaolin worker` does) =="
llm3 = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(tool_calls: [{ name: "lookup", arguments: { id: "cust-99" } }]),
  Shaolin::LLM::Completion.new(text: "Worker-driven answer.")
)
Shaolin::Kernel.register("llm.client", llm3)
Shaolin::Jobs::OutboxJob.delete_all # clear the no-op jobs the sync/resume runs enqueued, for a clean count
driver = Shaolin::Harness::Runner.new(harness: SupportTriage, llm: llm3, repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: bus)
wid = driver.start(input: { text: "drive me" }) # entry GateEntered -> 1 outbox job
worker = Shaolin::Jobs::Worker.new(event_store: Shaolin::Kernel["cqrs.event_store"])
steps = 0
until driver.load(wid).terminal?
  worker.run_once # each gate's DriveReactor advance enqueues the next gate
  steps += 1
  break if steps > 20
end
wrun = driver.load(wid)
puts "  worker steps: #{steps}, status: #{wrun.status}, output: #{wrun.output.inspect}"
puts "  outbox jobs done: #{Shaolin::Jobs::OutboxJob.where(status: 'done').count}"
raise "worker drive failed" unless wrun.completed? && wrun.output[:answer] == "Worker-driven answer."

puts "\n✅ shaolin harness OK — event-sourced gates, tool=command; sync + durable resume + worker-driven outbox loop (deterministic, no network)"

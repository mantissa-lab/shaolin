# A runnable CONVERSATION demo (issue #2): a long-lived, human-paced companion —
# the conversational MODE of the harness state machine. Each inbound message is
# one turn (safety → respond → rest at an await gate); state (funnel stage +
# history) enriches across turns; the run never terminates. Deterministic on the
# InMemory LLM — no network, no key.
#
#   createdb -h /tmp -p 5433 -U postgres shaolin_conversation_example
#   ruby examples/conversation/verify.rb
require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/llm"
require "shaolin/harness"

DB = {
  adapter: "postgresql", database: ENV.fetch("DB_NAME", "shaolin_conversation_example"),
  username: ENV.fetch("DB_USER", "postgres"), host: ENV.fetch("DB_HOST", "/tmp"),
  port: Integer(ENV.fetch("DB_PORT", "5433"))
}.freeze

# A per-turn side-effect tool (a command on the bus): mark that an offer landed.
class RecordOffer
  def initialize(**) = nil
end

class Companion < Shaolin::Conversation
  harness_name "companion"
  llm model: "stub"

  stages :onboarding, :free, :offer, :subscriber          # the funnel (a strict machine)
  edges  onboarding: :free, free: :offer, offer: :subscriber
  window 10                                                 # recent-message memory
  context { |run| "You are a warm companion. Funnel stage=#{run.stage}. Be brief." }

  gate :safety, entry: true, to: %i[respond refuse] do      # classify each inbound message
    prompt { |run| "Is this safe to answer? Reply safe/unsafe: #{run.recent(1).last[:content]}" }
    on_result { |out, run| run.transition_to(out.text == "unsafe" ? :refuse : :respond) }
  end

  gate :respond, to: %i[awaiting_user] do                   # no prompt => persona context + history
    tools record_offer: RecordOffer
    on_result do |out, run|
      run.advance_to(:offer) if out.tool_used?(:record_offer) && run.stage == "free"
      run.advance_to(:free)  if run.stage == "onboarding"   # first real exchange graduates onboarding
      run.transition_to(:awaiting_user)                     # rest until the next human message
    end
  end

  gate :refuse, reply: "I can't help with that — but I'm here if you want to talk about something else.",
       to: %i[awaiting_user] do # canned: fixed text, NO LLM call (issue #3)
    on_result { |_out, run| run.transition_to(:awaiting_user) }
  end

  gate :awaiting_user, await: true                          # the resting state between turns
end

# Deterministic script: each turn = [safety verdict, responder output]. The
# refused turn (#3) consumes only the safety verdict — the canned refuse gate
# makes no LLM call.
llm = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(text: "safe"),   Shaolin::LLM::Completion.new(text: "Hey! Glad you're here 😊"),             # turn 1
  Shaolin::LLM::Completion.new(text: "safe"),   Shaolin::LLM::Completion.new(text: "Want to try premium?", tool_calls: [{ name: "record_offer", arguments: {} }]), # turn 2 (offer)
  Shaolin::LLM::Completion.new(text: "unsafe"),                                                                              # turn 3 (refused — canned, no responder call)
  Shaolin::LLM::Completion.new(text: "safe"),   Shaolin::LLM::Completion.new(text: "Still here for you.")                    # turn 4
)

Shaolin::AR.register_provider!(config: DB)
Shaolin::CQRS.register_provider!
Shaolin::LLM.register_provider!(client: llm)
Shaolin::Provider.start_all

bus = Shaolin::Kernel["cqrs.command_bus"]
offers = []
bus.register(RecordOffer, ->(_cmd) { offers << :offered })

session = Companion.session(
  id: Shaolin::Id.generate, llm: Shaolin::Kernel["llm.client"],
  repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: bus
)

puts "== a human-paced conversation (one turn per inbound message) =="
[["hi there", "free"], ["got anything for me?", "offer"], ["do something bad", "offer"], ["thanks", "offer"]].each do |msg, _|
  reply = session.receive(msg)
  puts "  user: #{msg.inspect}"
  puts "  bot:  #{reply.inspect}    [stage=#{session.stage}, awaiting=#{session.awaiting?}, terminal=#{session.run.terminal?}]"
end

puts "\n== conversation state =="
puts "  stage:   #{session.stage}"
puts "  offers:  #{offers.size}"
puts "  history: #{session.history.size} messages (#{session.history.count { |m| m[:role] == 'user' }} user / #{session.history.count { |m| m[:role] == 'assistant' }} assistant)"

raise "should rest, never terminate" if session.run.terminal?
raise "should be awaiting the next message" unless session.awaiting?
raise "funnel should have advanced onboarding→free→offer" unless session.stage == "offer"
raise "the offer tool should have run as a command" unless offers.size == 1
raise "history should hold 4 user + 4 assistant turns" unless session.history.size == 8
raise "history must interleave user/assistant" unless session.history.first == { role: "user", content: "hi there" }

puts "\n✅ shaolin conversation OK — human-paced turns, enriching funnel stage (strict), tool=command, recent-window memory; one event-sourced run, rests at await, never terminal (deterministic, no network)"

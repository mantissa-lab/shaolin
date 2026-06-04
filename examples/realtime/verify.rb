# A realtime voice loop on the InMemory adapter — deterministic, no network, no
# provider. Proves the provider-agnostic substrate: send audio -> streamed
# transcript + tool_call -> dispatch the tool (here a plain handler; in an app a
# command on the bus) -> send the result -> turn completes. Swap InMemory for
# Shaolin::LLM::Realtime::OpenAI (with a WebSocket transport) and nothing else
# changes.
#
#   ruby examples/realtime/verify.rb
require "shaolin/llm"

R = Shaolin::LLM::Realtime
Event = R::Event

# Script the model's two turns (what a real provider would stream back).
client = R::InMemory.new
client.script_turn([
  Event.new(:transcript_delta, text: "Sure, checking your account…", role: "assistant"),
  Event.new(:tool_call, id: "c1", name: "lookup_account", arguments: { id: "cust-42" })
])
client.script_turn([
  Event.new(:transcript_delta, text: "You're on the premium plan.", role: "assistant"),
  Event.new(:turn_completed, transcript: "You're on the premium plan.")
])

# A "tool" — in a shaolin app this dispatches a Command on the bus.
def lookup_account(id) = "acct(#{id})=premium"

transcript = +""
session = client.connect(model: "gpt-realtime", tools: [{ name: "lookup_account" }])
session.on_event do |event|
  case event.type
  when :session_started then puts "  [session open]"
  when :transcript_delta then transcript << event[:text]; puts "  assistant: #{event[:text]}"
  when :tool_call
    puts "  [tool_call] #{event[:name]}(#{event[:arguments].inspect})"
    result = lookup_account(event[:arguments][:id])           # = command_bus.call(...) in an app
    session.tool_result(event[:id], result)
  when :turn_completed then puts "  [turn complete]"
  when :session_closed then puts "  [session closed]"
  end
end

puts "== caller speaks (audio frames) =="
R::Audio.frames("RAWPCM" * 50, ms: 20).each { |frame| session.send_audio(frame) }

puts "\n== turn 1 (transcript + tool call) =="
session.commit
puts "\n== turn 2 (final answer) =="
session.commit
session.close

raise "tool not invoked" unless session.tool_results == [["c1", "acct(cust-42)=premium"]]
raise "transcript wrong" unless transcript == "Sure, checking your account…You're on the premium plan."
raise "audio not sent" if session.sent_audio.empty?

puts "\n✅ shaolin realtime OK — provider-agnostic substrate: audio in, streamed transcript, tool=command, turn complete (no network)"

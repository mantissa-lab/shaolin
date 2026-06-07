module Shaolin
  class Harness
    # One gate (state) of a harness: how to build its prompt, which tools (mapped
    # to commands) it may call, and what to do with the model's result.
    # `transitions` are the DECLARED possible next gates (`to:`), used only for
    # describe/graph — the runtime transition is still whatever `on_result` calls.
    Gate = Struct.new(:name, :entry, :terminal, :await, :prompt, :reply, :response_format,
                      :params, :tools, :on_result, :transitions, keyword_init: true) do
      def tool_names = (tools || {}).keys
      def transition_names = (transitions || []).map(&:to_s)
      # A resting state for human-paced conversation: the run parks here between
      # turns. Non-terminal, but `advance` does no work until the next inbound
      # message wakes it (so a conversation never self-perpetuates).
      def await? = !!await
      # A canned gate replies with fixed text and makes NO LLM call (refusals,
      # nudges, scripted onboarding) — deterministic, zero tokens/latency.
      def canned? = !reply.nil?
    end

    # Block DSL collected inside `gate :name do ... end`.
    class GateBuilder
      def initialize(name, entry, terminal, transitions = [], await: false, reply: nil)
        @name = name.to_s
        @entry = entry
        @terminal = terminal
        @transitions = transitions
        @await = await
        @prompt = nil
        @reply = reply
        @response_format = nil
        @params = nil
        @tools = {}
        @on_result = nil
      end

      # prompt("text") or prompt { |run| "..." } (string => one user message,
      # or return an array of {role:, content:} messages).
      def prompt(value = nil, &block)
        @prompt = block || value
      end

      # Canned reply (no LLM call): reply("text") or reply { |run| "..." }.
      def reply(value = nil, &block)
        @reply = block || value
      end

      # Structured output for classification/decision gates: response_format(hash)
      # or response_format { |run| ... } — passed to the LLM; the parsed object
      # arrives on `out.data` in on_result.
      def response_format(value = nil, &block)
        @response_format = block || value
      end

      # Sampling params for this gate's LLM call: params(max_tokens: 4096) or
      # params { |run| ... }. Merged into the request (overrides adapter defaults)
      # — e.g. a generous max_tokens for a heavy reasoning gate.
      def params(value = nil, &block)
        @params = block || value
      end

      # tools(lookup: LookupAccount, place: PlaceOrder) — name the model sees =>
      # the Command class dispatched on the bus when the model calls it.
      def tools(**mapping)
        @tools.merge!(mapping)
      end

      def on_result(&block)
        @on_result = block
      end

      def build
        Gate.new(name: @name, entry: @entry, terminal: @terminal, await: @await,
                 prompt: @prompt, reply: @reply, response_format: @response_format,
                 params: @params, tools: @tools, on_result: @on_result, transitions: @transitions)
      end
    end
  end
end

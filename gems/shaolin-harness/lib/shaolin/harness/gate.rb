module Shaolin
  class Harness
    # One gate (state) of a harness: how to build its prompt, which tools (mapped
    # to commands) it may call, and what to do with the model's result.
    # `transitions` are the DECLARED possible next gates (`to:`), used only for
    # describe/graph — the runtime transition is still whatever `on_result` calls.
    Gate = Struct.new(:name, :entry, :terminal, :await, :prompt, :tools, :on_result, :transitions, keyword_init: true) do
      def tool_names = (tools || {}).keys
      def transition_names = (transitions || []).map(&:to_s)
      # A resting state for human-paced conversation: the run parks here between
      # turns. Non-terminal, but `advance` does no work until the next inbound
      # message wakes it (so a conversation never self-perpetuates).
      def await? = !!await
    end

    # Block DSL collected inside `gate :name do ... end`.
    class GateBuilder
      def initialize(name, entry, terminal, transitions = [], await: false)
        @name = name.to_s
        @entry = entry
        @terminal = terminal
        @transitions = transitions
        @await = await
        @prompt = nil
        @tools = {}
        @on_result = nil
      end

      # prompt("text") or prompt { |run| "..." } (string => one user message,
      # or return an array of {role:, content:} messages).
      def prompt(value = nil, &block)
        @prompt = block || value
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
                 prompt: @prompt, tools: @tools, on_result: @on_result, transitions: @transitions)
      end
    end
  end
end

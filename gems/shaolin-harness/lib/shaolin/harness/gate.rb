module Shaolin
  class Harness
    # One gate (state) of a harness: how to build its prompt, which tools (mapped
    # to commands) it may call, and what to do with the model's result.
    Gate = Struct.new(:name, :entry, :terminal, :prompt, :tools, :on_result, keyword_init: true) do
      def tool_names = (tools || {}).keys
    end

    # Block DSL collected inside `gate :name do ... end`.
    class GateBuilder
      def initialize(name, entry, terminal)
        @name = name.to_s
        @entry = entry
        @terminal = terminal
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
        Gate.new(name: @name, entry: @entry, terminal: @terminal,
                 prompt: @prompt, tools: @tools, on_result: @on_result)
      end
    end
  end
end

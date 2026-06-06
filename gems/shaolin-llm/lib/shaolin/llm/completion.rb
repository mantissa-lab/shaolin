module Shaolin
  module LLM
    # The result of an LLM call: clean free-text `text`, the model's `reasoning`
    # trace (chain-of-thought, when the provider exposes it — via a separate field
    # or an inline `<think>` block the adapter lifted out; nil otherwise), any
    # `tool_calls` the model requested ([{ name:, arguments: {} }]), and token
    # `usage`. Transport-agnostic — every adapter (InMemory, OpenAI, ...) returns
    # this shape. Harnesses persist `reasoning` in their event log (auditable
    # replay) while showing only `text` to the user.
    class Completion
      attr_reader :text, :reasoning, :tool_calls, :usage

      def initialize(text: nil, reasoning: nil, tool_calls: [], usage: {})
        @text = text
        @reasoning = reasoning
        @tool_calls = tool_calls || []
        @usage = usage || {}
      end

      def tool_calls? = !@tool_calls.empty?
      def tool_used?(name) = @tool_calls.any? { |tc| tc[:name].to_s == name.to_s }
      def reasoning? = !(@reasoning.nil? || @reasoning.empty?)
      def to_h = { text: text, reasoning: reasoning, tool_calls: tool_calls, usage: usage }
    end
  end
end

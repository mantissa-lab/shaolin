module Shaolin
  module LLM
    # The result of an LLM call: free-text `text`, any `tool_calls` the model
    # requested ([{ name:, arguments: {} }]), and token `usage`. Transport-agnostic
    # — every adapter (InMemory, OpenAI, ...) returns this shape.
    class Completion
      attr_reader :text, :tool_calls, :usage

      def initialize(text: nil, tool_calls: [], usage: {})
        @text = text
        @tool_calls = tool_calls || []
        @usage = usage || {}
      end

      def tool_calls? = !@tool_calls.empty?
      def tool_used?(name) = @tool_calls.any? { |tc| tc[:name].to_s == name.to_s }
      def to_h = { text: text, tool_calls: tool_calls, usage: usage }
    end
  end
end

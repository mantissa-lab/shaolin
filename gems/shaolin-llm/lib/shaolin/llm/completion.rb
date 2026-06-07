module Shaolin
  module LLM
    # The result of an LLM call: clean free-text `text`, the model's `reasoning`
    # trace (chain-of-thought, when the provider exposes it — via a separate field
    # or an inline `<think>` block the adapter lifted out; nil otherwise), any
    # `tool_calls` the model requested ([{ name:, arguments: {} }]), and token
    # `usage`. When a structured output is requested (`response_format:`), the
    # parsed object is on `data` (a Hash with symbol keys; nil otherwise) — for
    # classification/decision gates that want a typed verdict instead of a tool or
    # free-text parsing. Transport-agnostic — every adapter (InMemory, OpenAI, ...)
    # returns this shape. Harnesses persist `reasoning` in their event log
    # (auditable replay) while showing only `text` to the user.
    class Completion
      attr_reader :text, :reasoning, :tool_calls, :usage, :data, :finish_reason

      def initialize(text: nil, reasoning: nil, tool_calls: [], usage: {}, data: nil, finish_reason: nil)
        @text = text
        @reasoning = reasoning
        @tool_calls = tool_calls || []
        @usage = usage || {}
        @data = data
        @finish_reason = finish_reason
      end

      def tool_calls? = !@tool_calls.empty?
      def tool_used?(name) = @tool_calls.any? { |tc| tc[:name].to_s == name.to_s }
      def reasoning? = !(@reasoning.nil? || @reasoning.empty?)
      def data? = !@data.nil?
      # The choice's stop reason ("stop"/"length"/"tool_calls"/…). `truncated?`
      # flags a reply cut off at the token budget — e.g. a reasoning model that
      # spent it all inside <think> and returned empty text — so callers can retry
      # with a higher max_tokens instead of mistaking it for a legitimate stop.
      def truncated? = @finish_reason == "length"
      def to_h
        { text: text, reasoning: reasoning, tool_calls: tool_calls, usage: usage,
          data: data, finish_reason: finish_reason }
      end
    end
  end
end

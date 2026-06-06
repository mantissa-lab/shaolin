module Shaolin
  module LLM
    # The provider-agnostic chat-completion port. `messages` is an array of
    # { role:, content: } hashes; `tools` is an array of function/tool schemas
    # ({ name:, description:, parameters: }). `response_format` (opt-in) requests a
    # structured output (e.g. `{ type: "json_schema", json_schema: {...} }` or
    # `{ type: "json_object" }`) — the parsed object comes back on `Completion#data`.
    # Returns a Completion. A concrete adapter (InMemory, OpenAI, ...) implements it.
    #
    # (Realtime/audio streaming is a separate port — phase 2.)
    module Client
      def complete(messages:, tools: [], model: nil, response_format: nil)
        raise NotImplementedError, "#{self.class} must implement #complete"
      end
    end
  end
end

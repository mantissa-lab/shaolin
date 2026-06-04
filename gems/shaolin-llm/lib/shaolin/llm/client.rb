module Shaolin
  module LLM
    # The provider-agnostic chat-completion port. `messages` is an array of
    # { role:, content: } hashes; `tools` is an array of function/tool schemas
    # ({ name:, description:, parameters: }). Returns a Completion. A concrete
    # adapter (InMemory, OpenAI, ...) implements #complete.
    #
    # (Realtime/audio streaming is a separate port — phase 2.)
    module Client
      def complete(messages:, tools: [], model: nil)
        raise NotImplementedError, "#{self.class} must implement #complete"
      end
    end
  end
end

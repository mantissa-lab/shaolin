require "shaolin/core"
require_relative "openai"

module Shaolin
  module LLM
    # The :llm provider registers the chat client as `llm.client` in the kernel.
    # Pass a client (e.g. InMemory in tests); default is the OpenAI adapter
    # configured from ENV (OPENAI_API_KEY, OPENAI_MODEL).
    def self.register_provider!(client: nil)
      Shaolin.register_provider(:llm) do
        start do
          resolved = client || OpenAI.new(model: ENV.fetch("OPENAI_MODEL", "gpt-4.1"))
          Shaolin::Kernel.register("llm.client", resolved)
        end
      end
    end
  end
end

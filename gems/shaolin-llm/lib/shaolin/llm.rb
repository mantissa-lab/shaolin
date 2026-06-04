require_relative "llm/version"
require_relative "llm/completion"
require_relative "llm/client"
require_relative "llm/in_memory"
require_relative "llm/openai"
require_relative "llm/provider"

module Shaolin
  # Provider-agnostic LLM port (chat completions + function/tool calling) with an
  # InMemory stub (tests/replay) and an OpenAI adapter. Realtime/audio is a
  # separate, later port. See Shaolin::LLM::Client.
  module LLM
  end
end

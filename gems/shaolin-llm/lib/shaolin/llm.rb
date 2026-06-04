require_relative "llm/version"
require_relative "llm/completion"
require_relative "llm/client"
require_relative "llm/in_memory"
require_relative "llm/openai"
require_relative "llm/provider"
require_relative "llm/realtime"

module Shaolin
  # Provider-agnostic LLM ports: chat completions + function/tool calling
  # (Shaolin::LLM::Client, InMemory/OpenAI adapters) AND a realtime/audio
  # streaming substrate (Shaolin::LLM::Realtime: normalized events, audio helpers,
  # a Session/Client port, an InMemory adapter to build & test without a provider).
  module LLM
  end
end

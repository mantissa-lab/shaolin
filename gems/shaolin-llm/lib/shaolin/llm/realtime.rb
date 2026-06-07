require "shaolin/core"
require_relative "realtime/audio"
require_relative "realtime/event"
require_relative "realtime/session"
require_relative "realtime/in_memory"
require_relative "realtime/openai"
require_relative "realtime/web_socket_transport"

module Shaolin
  module LLM
    # Provider-agnostic realtime (streaming, bidirectional, audio) substrate:
    # normalized session Events, an Audio helper, a Session/Client port, and an
    # InMemory adapter to build & test realtime apps with no provider. Concrete
    # adapters (OpenAI Realtime, Gemini Live, ...) implement Client/Session over
    # their WebSocket transport and map their wire events to Realtime::Event.
    module Realtime
      # Registers a realtime client as `realtime.client` (e.g. InMemory in tests).
      def self.register_provider!(client:)
        Shaolin.register_provider(:realtime) do
          start { Shaolin::Kernel.register("realtime.client", client) }
        end
      end
    end
  end
end

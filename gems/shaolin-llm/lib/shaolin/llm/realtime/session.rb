require_relative "event"

module Shaolin
  module LLM
    module Realtime
      # A live, bidirectional realtime session — the provider-agnostic interface
      # the app/harness talks to. You register handlers with `on_event`; you push
      # input with `send_audio` / `send_text`, `commit` an input turn, answer a
      # `:tool_call` with `tool_result`, and `close`. Adapters (InMemory, OpenAI,
      # Gemini, ...) subclass this and `emit` normalized Realtime::Event objects.
      class Session
        def initialize
          @handlers = []
        end

        def on_event(&block) = (@handlers << block)

        # Called by the adapter to deliver a normalized server event upstream.
        def emit(event)
          @handlers.each { |h| h.call(event) }
          event
        end

        # --- write side: adapters implement against their transport ---
        def send_audio(_bytes) = raise NotImplementedError, "#{self.class} must implement #send_audio"
        def send_text(_text) = raise NotImplementedError, "#{self.class} must implement #send_text"
        def commit = raise NotImplementedError, "#{self.class} must implement #commit"
        def tool_result(_call_id, _result) = raise NotImplementedError, "#{self.class} must implement #tool_result"
        def close = raise NotImplementedError, "#{self.class} must implement #close"
      end

      # The connection port: open a session for a model (with optional tools and
      # system instructions).
      module Client
        def connect(model:, tools: [], instructions: nil)
          raise NotImplementedError, "#{self.class} must implement #connect"
        end
      end
    end
  end
end

require "json"
require_relative "session"
require_relative "event"
require_relative "audio"

module Shaolin
  module LLM
    module Realtime
      # OpenAI Realtime adapter — proof that a concrete provider plugs into the
      # substrate. It maps OpenAI's WebSocket wire events to normalized
      # Realtime::Events (`translate`) and the session's writes to OpenAI client
      # events. The raw socket is a `transport` you inject (responds to
      # `#send(hash)`, `#on_message { |hash| }`, `#close`) — tests use a fake; for
      # live use, wrap a WebSocket gem (e.g. faye-websocket / async-websocket) to
      # `wss://api.openai.com/v1/realtime?model=...` with the Authorization header.
      # So both directions are unit-testable without a network.
      class OpenAI
        include Client

        def initialize(api_key: ENV["OPENAI_API_KEY"], model: "gpt-4o-realtime-preview", transport: nil)
          @api_key = api_key
          @model = model
          @transport = transport
        end

        def connect(model: nil, tools: [], instructions: nil)
          transport = @transport || raise("inject a WebSocket transport (see Shaolin::LLM::Realtime::OpenAI docs)")
          Session.new(transport, tools: tools, instructions: instructions)
        end

        # OpenAI server event (Hash) -> normalized Realtime::Event (or nil to ignore).
        def self.translate(ev)
          case ev["type"]
          when "session.created"
            Event.new(:session_started)
          when "response.audio_transcript.delta", "response.text.delta"
            Event.new(:transcript_delta, text: ev["delta"], role: "assistant")
          when "response.audio.delta"
            Event.new(:audio_delta, audio: Audio.decode(ev["delta"]))
          when "response.function_call_arguments.done"
            Event.new(:tool_call, id: ev["call_id"], name: ev["name"], arguments: parse_args(ev["arguments"]))
          when "response.done"
            Event.new(:turn_completed)
          when "error"
            Event.new(:error, message: ev.dig("error", "message"))
          end
        end

        def self.parse_args(json)
          json.to_s.empty? ? {} : JSON.parse(json, symbolize_names: true)
        rescue JSON::ParserError
          {}
        end

        class Session < Realtime::Session
          def initialize(transport, tools: [], instructions: nil)
            super()
            @transport = transport
            @transport.on_message { |raw| dispatch(raw) }
            configure(tools, instructions)
          end

          def send_audio(bytes)
            @transport.send(type: "input_audio_buffer.append", audio: Audio.encode(bytes))
          end

          def send_text(text)
            @transport.send(type: "conversation.item.create",
                            item: { type: "message", role: "user", content: [{ type: "input_text", text: text }] })
          end

          def commit
            @transport.send(type: "input_audio_buffer.commit")
            @transport.send(type: "response.create")
          end

          def tool_result(call_id, result)
            @transport.send(type: "conversation.item.create",
                            item: { type: "function_call_output", call_id: call_id, output: result.to_s })
          end

          def close = @transport.close

          private

          def configure(tools, instructions)
            session = {}
            session[:instructions] = instructions if instructions
            session[:tools] = tools.map { |t| { type: "function", **t } } unless tools.empty?
            @transport.send(type: "session.update", session: session) unless session.empty?
          end

          def dispatch(raw)
            event = OpenAI.translate(raw)
            emit(event) if event
          end
        end
      end
    end
  end
end

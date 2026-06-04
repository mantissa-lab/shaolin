require_relative "session"
require_relative "event"

module Shaolin
  module LLM
    module Realtime
      # Scriptable in-process realtime adapter — build and TEST voice/realtime
      # flows with NO provider and NO network. Script the model's turns as lists
      # of normalized events; each `commit` plays the next turn to the handlers.
      # Records everything the app sent (audio, text, tool results) for assertions.
      #
      #   client = Shaolin::LLM::Realtime::InMemory.new
      #   client.script_turn([Event.new(:transcript_delta, text: "hi"), Event.new(:turn_completed)])
      #   s = client.connect(model: "stub"); s.on_event { |e| ... }
      #   s.send_audio(pcm); s.commit
      class InMemory
        include Client

        def initialize
          @turns = []
        end

        # Queue a model turn (list of events) to be played on the next commit.
        def script_turn(events)
          @turns << events
          self
        end

        def connect(model:, tools: [], instructions: nil)
          @session = Session.new(@turns)
        end

        attr_reader :session

        # The session backed by the scripted turns.
        class Session < Realtime::Session
          attr_reader :sent_audio, :sent_text, :tool_results, :closed

          def initialize(turns)
            super()
            @turns = turns
            @sent_audio = []
            @sent_text = []
            @tool_results = []
            @closed = false
            @started = false
          end

          def send_audio(bytes) = (@sent_audio << bytes)
          def send_text(text) = (@sent_text << text)
          def tool_result(call_id, result) = (@tool_results << [call_id, result])

          def commit
            unless @started
              @started = true
              emit(Event.new(:session_started))
            end
            Array(@turns.shift).each { |event| emit(event) }
          end

          def close
            return if @closed

            @closed = true
            emit(Event.new(:session_closed))
          end
        end
      end
    end
  end
end

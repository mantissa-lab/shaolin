module Shaolin
  module LLM
    module Realtime
      # A normalized realtime session event — the single vocabulary every adapter
      # maps its provider's wire events into, so harness/app code is
      # provider-agnostic. `type` is one of TYPES; `data` carries the payload.
      #
      #   :session_started   {}
      #   :transcript_delta  { text:, role: }          # streamed text (you or model)
      #   :audio_delta       { audio: <bytes> }         # streamed output audio
      #   :tool_call         { id:, name:, arguments: } # model wants a tool
      #   :turn_completed     { transcript: }            # end of a model turn
      #   :error             { message: }
      #   :session_closed    {}
      class Event
        TYPES = %i[session_started transcript_delta audio_delta tool_call turn_completed error session_closed].freeze

        attr_reader :type, :data

        def initialize(type, **data)
          @type = type.to_sym
          @data = data
        end

        def [](key) = @data[key]
        def to_h = { type: @type, **@data }
      end
    end
  end
end

require "ruby_event_store"

module Shaolin
  class Harness
    # The event-sourced history of a harness run — its full audit trail and the
    # basis for replay/resume. One stream per run.
    module Events
      class RunStarted   < RubyEventStore::Event; end
      class GateEntered  < RubyEventStore::Event; end
      class Prompted     < RubyEventStore::Event; end
      class Responded    < RubyEventStore::Event; end
      class ToolInvoked  < RubyEventStore::Event; end
      class ToolReturned < RubyEventStore::Event; end
      class Transitioned < RubyEventStore::Event; end
      class Completed    < RubyEventStore::Event; end
      class Failed       < RubyEventStore::Event; end

      # Conversational mode (human-paced): an inbound human message starts a turn;
      # Replied is the turn's user-facing reply (its assistant history entry —
      # distinct from per-gate Responded, which is the full audit incl. internal
      # classification gates); StageChanged advances the funnel (strict).
      class MessageReceived < RubyEventStore::Event; end
      class Replied         < RubyEventStore::Event; end
      class StageChanged    < RubyEventStore::Event; end
    end
  end
end

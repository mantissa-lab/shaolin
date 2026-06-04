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
    end
  end
end

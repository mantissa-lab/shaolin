require "ruby_event_store"

module Signups
  module Events
    # Domain event: a signup finished. Appended to the event store inside the
    # write transaction; the :jobs provider mirrors it into the outbox for any
    # reactor that subscribes.
    class SignupCompleted < RubyEventStore::Event; end
  end
end

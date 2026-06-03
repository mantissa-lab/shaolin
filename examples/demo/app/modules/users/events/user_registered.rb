require "ruby_event_store"

module Users
  module Events
    class UserRegistered < RubyEventStore::Event; end
  end
end

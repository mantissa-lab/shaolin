require "ruby_event_store"

module Orders
  module Events
    class OrderPlaced < RubyEventStore::Event; end
  end
end

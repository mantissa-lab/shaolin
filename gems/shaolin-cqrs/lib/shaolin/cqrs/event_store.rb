require "ruby_event_store"

module Shaolin
  module CQRS
    # Factory for the RubyEventStore client. `in_memory` is used in tests and in
    # monolith/dev mode before a durable backend (shaolin-activerecord) is
    # registered; `build` wraps an injected repository (the AR-backed one in prod).
    module EventStore
      def self.in_memory
        build(repository: RubyEventStore::InMemoryRepository.new)
      end

      def self.build(repository:)
        RubyEventStore::Client.new(repository: repository)
      end
    end
  end
end

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

      # `mapper:` is the extension point for event versioning / upcasting: pass a
      # RubyEventStore::Mappers::PipelineMapper whose transformations include
      # `Transformation::Upcast.new(...)` and old event versions are rewritten to
      # the current shape on read. Nil uses RES's default mapper. See docs/EVENTS.md.
      def self.build(repository:, mapper: nil)
        if mapper
          RubyEventStore::Client.new(repository: repository, mapper: mapper)
        else
          RubyEventStore::Client.new(repository: repository)
        end
      end
    end
  end
end

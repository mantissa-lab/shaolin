require "aggregate_root"
require_relative "stream_name"

module Shaolin
  module CQRS
    # Loads and stores event-sourced aggregates, deriving the stream name from
    # the aggregate's class + id (so callers never build stream names by hand).
    # Wraps AggregateRoot::Repository (transactional, optimistic concurrency).
    class AggregateRepository
      def initialize(event_store)
        @repository = AggregateRoot::Repository.new(event_store)
      end

      # Load the aggregate, yield it for mutation, then persist new events.
      def unit_of_work(aggregate, &block)
        stream = CQRS.stream_name(aggregate.class, aggregate.id)
        @repository.with_aggregate(aggregate, stream, &block)
      end

      # Rebuild an aggregate of `aggregate_class` with the given id by replay.
      def load(aggregate_class, id)
        @repository.load(aggregate_class.new(id), CQRS.stream_name(aggregate_class, id))
      end
    end
  end
end

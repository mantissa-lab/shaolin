require "aggregate_root"
require_relative "stream_name"

module Shaolin
  module CQRS
    # Loads and stores event-sourced aggregates, deriving the stream name from
    # the aggregate's class + id (so callers never build stream names by hand).
    # Wraps AggregateRoot::Repository (transactional, optimistic concurrency).
    #
    # Snapshots (for very large/long-lived aggregates) are available via
    # aggregate_root's SnapshotRepository but not wired here yet — see docs/EVENTS.md.
    class AggregateRepository
      # `transaction` is an optional callable taking a block. When supplied (the
      # :active_record provider registers one as `cqrs.transaction`), the whole
      # unit of work — event append + synchronous subscribers (projections AND
      # the outbox enqueue) — runs inside ONE database transaction. That is what
      # makes the transactional outbox actually atomic: a crash can never leave
      # an event persisted without its outbox row. Without a runner (e.g. the
      # in-memory store) the block just runs directly.
      def initialize(event_store, transaction: nil)
        @repository = AggregateRoot::Repository.new(event_store)
        @transaction = transaction
      end

      # Load the aggregate, yield it for mutation, then persist new events —
      # atomically when a transaction runner is configured.
      def unit_of_work(aggregate, &block)
        stream = CQRS.stream_name(aggregate.class, aggregate.id)
        in_transaction { @repository.with_aggregate(aggregate, stream, &block) }
      end

      # Rebuild an aggregate of `aggregate_class` with the given id by replay.
      def load(aggregate_class, id)
        @repository.load(aggregate_class.new(id), CQRS.stream_name(aggregate_class, id))
      end

      private

      def in_transaction(&block)
        @transaction ? @transaction.call(&block) : block.call
      end
    end
  end
end

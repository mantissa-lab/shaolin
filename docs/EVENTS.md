# Evolving events in shaolin

Events are the source of truth and are **immutable once stored**. You never edit or delete a
stored event — you evolve the system around it. This guide covers how.

## Golden rules

1. **Never mutate or delete stored events.** Read models are derived and rebuildable
   (`shaolin projections rebuild`); the event log is not.
2. **Prefer additive changes.** Adding a new optional field to an event's `data` is safe — old
   events simply lack it; handlers/projections default it.
3. **Version by new event type for breaking changes.** If the meaning changes incompatibly,
   introduce `Users::Events::UserRegisteredV2` and have aggregates emit the new one going forward;
   projections handle both (`on UserRegistered` and `on UserRegisteredV2`).

## Upcasting old events (transformations)

When you want consumers to see only the new shape, transform old events on read instead of editing
them. RubyEventStore supports mapper/transformation pipelines: register a transformation that
"upcasts" `UserRegistered` → `UserRegisteredV2` (fill defaults, rename keys) when events are read.
Stored bytes stay untouched; code sees the upcasted version. Add the transformation where the
event store client is built (the `:cqrs` provider / `Shaolin::CQRS::EventStore`).

```ruby
# sketch — register an upcaster in your app boot:
upcaster = ->(record) { record.event_type == "Users::Events::UserRegistered" ? upcast(record) : record }
# wire into the RubyEventStore::Client mapper pipeline
```

## Rebuilding read models

Because read models are projections of the event log, after changing a projection (new field,
fixed bug) you rebuild:

```bash
shaolin projections rebuild           # all modules
shaolin projections rebuild users     # one module
```

Read-model writes are idempotent upserts, so a rebuild is safe to run anytime.

## Snapshots (deferred)

For aggregates with very long event streams, replaying from zero on every load is wasteful.
`aggregate_root` ships an `AggregateRoot::SnapshotRepository` (marshalled snapshot every N events,
in a `<stream>_snapshots` stream). shaolin does not wire this into `AggregateRepository` yet — the
load/store/version dance needs care — so it is intentionally **deferred**. When needed, swap the
repository for `SnapshotRepository.new(event_store, interval)` for that aggregate. Most aggregates
have short streams and don't need it.

## Transactional outbox (implemented)

Async side effects go through a transactional outbox (`shaolin-jobs`). A reactor's enqueue runs as a
synchronous subscriber **inside the same DB transaction** as the event append (the aggregate
repository wraps the unit of work in `ActiveRecord::Base.transaction`), so a crash can never leave an
event without its job. `shaolin worker` drains the outbox with `FOR UPDATE SKIP LOCKED`, retries with
backoff, and dead-letters. Delivery is at-least-once → reactors must be idempotent (enqueue itself is
deduped by a unique `(reactor, event_id)`). Cross-service transports: `shaolin-rabbitmq`,
`shaolin-redis` (Streams).

## Event versioning / upcasting

Prefer **additive** changes (new optional fields with defaults read in the projection/aggregate). When
you must reshape an old event, register an upcasting mapper so old versions are rewritten to the
current shape on read — before the cqrs provider boots:

```ruby
require "ruby_event_store"
upcast = RubyEventStore::Mappers::Transformation::Upcast.new(
  "Orders::Events::OrderPlaced" => ->(record) {
    record.metadata[:schema_version] ||= 1
    record.data[:currency] ||= "USD"           # fill a field added in v2
    record
  }
)
mapper = RubyEventStore::Mappers::PipelineMapper.new(
  RubyEventStore::Mappers::Pipeline.new(upcast, to_domain_event: RubyEventStore::Mappers::Transformation::DomainEvent.new)
)
Shaolin::Kernel.register("cqrs.event_mapper", mapper)   # before Shaolin::CQRS.register_provider!
```

The event store is the source of truth; alternatively `shaolin projections rebuild` replays events
into read models after a projection change.

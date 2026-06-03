# shaolin-cqrs — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** [shaolin-core](2026-06-03-shaolin-core-design.md)
**Sub-project:** 2 of 10 (the CQRS/ES heart)

## 1. Purpose

`shaolin-cqrs` provides the CQRS + Event Sourcing building blocks, layered on **ruby_event_store**,
**aggregate_root**, and **arkency-command_bus**, and wired into the kernel through a single
`shaolin-core` provider. It gives modules a uniform way to define commands, aggregates, domain
events, command handlers, projections, read-model updates, and queries — while staying
transport-agnostic (HTTP and Kafka adapters only ever produce commands or carry events).

It does **not** own the event-store persistence backend or the read-model ORM — those are
`shaolin-activerecord`. It owns the *abstractions and wiring*; the AR repository and read-model
base are injected.

## 2. Foundation (verified 2026-06-03)

RES family, latest May 2026: `ruby_event_store` 2.17.x, `aggregate_root` 2.19.2,
`arkency-command_bus` ≥ 0.4. Confirmed API:

- Aggregate: `include AggregateRoot`; `apply(event)` records+applies; `on EventClass do |e| … end`
  DSL mutates state; `unpublished_events` lists pending events.
- Repository: `AggregateRoot::Repository.new(event_store)` → `.load(agg, stream)`,
  `.store(agg, stream)`, `.with_aggregate(agg, stream) { |a| … }` (transactional, optimistic
  concurrency via `expected_version`).
- Command bus: `Arkency::CommandBus.new`; `.register(CommandClass, ->(cmd){ … })`; invoke `bus.(cmd)`.
- Event store: `RubyEventStore::Client.new`; events are `RubyEventStore::Event` subclasses;
  `client.subscribe(handler, to: [EventClass])` for live subscribers.

> Exact patch versions and the AR-backed event-store repository class are pinned during planning
> (the backend lives in shaolin-activerecord).

## 3. Components & shaolin conventions

| Concept | RES primitive | shaolin convention (in a module folder) |
|---|---|---|
| Command | plain value object (dry-struct/contract) | `commands/register_user.rb` |
| Domain event | `RubyEventStore::Event` | `events/user_registered.rb` |
| Aggregate | `include AggregateRoot` + `on` DSL | `user_aggregate.rb` |
| Command handler | proc/object registered on the bus | `command_handlers/register_user_handler.rb` |
| Projection | event subscriber writing a read model | `projections/users_projection.rb` |
| Read model | ActiveRecord row (owned by shaolin-activerecord) | `read_models/user_record.rb` |
| Query | object reading read models | `queries/find_user.rb` |

## 4. Buses & registry

- **Command bus** (`Arkency::CommandBus`): one handler per command. `shaolin-cqrs` auto-registers
  each module's `command_handlers/*` against the command classes they declare to handle, resolving
  the handler (and its injected deps) from the **module container** (per shaolin-core DI). Handlers
  are registered as procs for per-call instantiation.
- **Event store / event bus** (`RubyEventStore::Client`): a single app-wide client (backend
  injected by shaolin-activerecord). Projections and reactors subscribe via `subscribe(..., to:)`.
- **Query bus**: a thin shaolin construct (RES has none) routing a query object to its query
  handler, resolved from the module container. Kept symmetric with the command bus.

## 5. Aggregate & repository conventions

- Aggregates `include AggregateRoot`, expose command methods that `apply` events, and mutate state
  only inside `on` handlers (pure replay).
- **Stream naming convention:** `"<Module>::<Aggregate>$<id>"` (e.g. `"Users::User$<uuid>"`),
  centralized in a `Shaolin::CQRS.stream_name(aggregate, id)` helper so it is never hand-built.
- Command handlers use `AggregateRoot::Repository#with_aggregate(agg, stream) { |a| a.command(...) }`
  for transactional load→mutate→store with optimistic concurrency.

## 6. Command handler shape

```ruby
# command_handlers/register_user_handler.rb
class RegisterUserHandler
  include Deps["cqrs.aggregate_repository"]   # injected from shaolin-cqrs provider

  def call(cmd)                                # cmd = RegisterUser
    stream = Shaolin::CQRS.stream_name(Users::User, cmd.id)
    aggregate_repository.with_aggregate(Users::User.new(cmd.id), stream) do |user|
      user.register(email: cmd.email, name: cmd.name)
    end
    Dry::Monads::Success(cmd.id)
  rescue AggregateRoot::Repository::Error, Users::User::InvariantError => e
    Dry::Monads::Failure([:conflict, e.message])
  end
end
```

Handlers return `dry-monads` `Success`/`Failure`; transports translate at the edge.

## 7. Projections & read models

- A projection is an event subscriber that updates a read model on each relevant event.
- `shaolin-cqrs` registers each module's `projections/*` against the events they subscribe to,
  using the manifest's `events:` declarations (own + imported) validated by shaolin-core.
- The **read-model write API** (idempotent upsert keyed by aggregate id) is provided by
  `shaolin-activerecord`; the projection calls it. shaolin-cqrs defines the *projection
  subscription contract*, not the table.
- **Rebuild:** a projection runner replays a stream (or `$all`) through a projection to rebuild a
  read model from scratch — exposed to the CLI as `shaolin projections rebuild <name>`.

## 8. Domain vs integration events (Kafka handoff)

- **Domain events** live in the event store (internal, fine-grained).
- A **reactor** subscribes to selected domain events and emits **integration events** to a
  messaging port (implemented by shaolin-kafka via WaterDrop). The reactor contract (which domain
  event → which integration event/topic) is declared per module and lives here; the actual
  publish is the messaging adapter's job.
- **Inbound:** a Kafka consumer maps a message to a command and dispatches it on the command bus —
  identical to the HTTP write path.

## 9. Dispatch model (sync vs async) — decision

- **Default: synchronous, in-process dispatch.** On `store`, RES publishes events; projections and
  reactors run synchronously in the same fiber/transaction boundary. Predictable, easy to reason
  about, safe under Falcon's fiber scheduler.
- **Async opt-in:** a subscriber may be marked async (handed to a background scheduler / Kafka),
  for heavy or cross-service work. Configurable per subscriber, off by default.
- Rationale: avoids surprising eventual-consistency in the simple case while leaving the door open.
  (Listed as a parent-spec risk; this is the resolution.)

## 10. Kernel integration (the provider)

`shaolin-cqrs` plugs into shaolin-core via one provider:

```ruby
Shaolin.register_provider(:cqrs) do
  start do
    # build event_store client (backend injected by shaolin-activerecord),
    # command bus, query bus, aggregate_repository; register them in the app container
    # under the "cqrs.*" namespace; then wire each module's handlers/projections/reactors
    # from its manifest.
  end
  stop { # flush async subscribers }
end
```

It reaches modules only through the shaolin-core registry/manifest — never their internals.

## 11. Public API

- `Shaolin::CQRS.stream_name(aggregate_class, id)` — canonical stream naming.
- Container keys (resolved via `Deps`): `cqrs.command_bus`, `cqrs.query_bus`,
  `cqrs.event_store`, `cqrs.aggregate_repository`.
- `Shaolin::CQRS::Command` / `::Query` base (dry-struct + contract) — optional value-object bases.
- Manifest hooks consumed: `commands_handled`, `events_published`, `imports events: [...]`.

## 12. Error handling

- **Optimistic concurrency conflict** (`expected_version` mismatch) → `Failure([:conflict, …])`;
  transport maps to HTTP 409 / Kafka retry.
- **Aggregate invariant violation** → `Failure([:unprocessable, …])` → HTTP 422.
- **Unregistered command** on the bus → boot-time validation error (caught when wiring against
  `commands_handled`), never a silent runtime miss.

## 13. Testing strategy

- `ruby_event_store-rspec` matchers (`have_published`, `have_applied`) to assert emitted/applied
  events on aggregates and the store.
- Aggregate unit tests (pure: apply events, assert state) with no persistence.
- Handler tests with an in-memory RES client; projection tests asserting read-model rows.
- Per-module isolation: boot one module's container with cqrs provider + in-memory store.

## 14. To verify during planning

- Exact `arkency-command_bus` 0.4 API (register/call signatures, error on missing handler).
- `aggregate_root` 2.19.2 repository API (`with_aggregate`, `expected_version` options) and
  Ruby 4.0 compat.
- RES subscriber dispatch under the fiber scheduler (sync subscribers + Falcon) — confirm no
  blocking surprises; validates the section 9 default.
- The precise AR-backed event-store repository class to inject (shaolin-activerecord spec).
- Whether the query bus should be a real bus or just convention over query objects — settle when
  writing shaolin-http (the main query consumer).

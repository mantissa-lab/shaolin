# CQRS & Event Sourcing

Reference for `shaolin-cqrs` (`Shaolin::CQRS`, v0.1.0) — the write/read core of the framework.
Commands mutate event-sourced **aggregates**; **events** are the source of truth (RubyEventStore);
**projections** build **read models** you query. Loading `require "shaolin/cqrs"` pulls every building
block below and (at the bottom of `cqrs.rb`) the `:cqrs` provider.

> Grounded in `gems/shaolin-cqrs/lib/shaolin/cqrs/`. The framework builds on `aggregate_root`,
> `ruby_event_store`, and `arkency-command_bus`. Aggregates and the in-memory store need **no DB**.

---

## At a glance

| Class / module | File | Role |
|---|---|---|
| `Shaolin::CQRS::CommandBus` | `command_bus.rb` | one handler per command class; dispatch + clear errors |
| `Shaolin::CQRS::QueryBus` | `query_bus.rb` | one handler per query class (read side) |
| `Shaolin::CQRS::Aggregate` | `aggregate.rb` | mixin: `apply`/`on` DSL + an `id` |
| `Shaolin::CQRS::CommandHandler` | `command_handler.rb` | base for handlers; `handles`, lazy `aggregate_repository`/`event_store` |
| `Shaolin::CQRS::QueryHandler` | `query_handler.rb` | base for read-side handlers; `handles` |
| `Shaolin::CQRS::Projection` | `projection.rb` | `on` event → write read model; sync (default) or `async` |
| `Shaolin::CQRS::ProjectionRunner` | `projection_runner.rb` | resumable replay/rebuild |
| `Shaolin::CQRS::EventStore` | `event_store.rb` | factory for the RES client (`in_memory`/`build`) |
| `Shaolin::CQRS::AggregateRepository` | `aggregate_repository.rb` | load/store aggregates; `unit_of_work` atomic outbox |
| `Shaolin::CQRS.stream_name` | `stream_name.rb` | canonical `"<Class>$<id>"` stream name |
| `Shaolin::CQRS.register_provider!` / `wire_modules` | `provider.rb` | `:cqrs` boot wiring |

Kernel keys published by the provider: `cqrs.event_store`, `cqrs.command_bus`, `cqrs.query_bus`,
`cqrs.aggregate_repository`. Keys it reads (optional, injected by other gems): `cqrs.event_store_backend`,
`cqrs.event_mapper`, `cqrs.transaction`, `kernel.containers`.

---

## CommandBus

Routes a command to its **single** registered handler. Wraps `Arkency::CommandBus` for dispatch but
tracks registrations itself so a missing handler raises a clear, machine-readable error.

| Method | Signature | Purpose |
|---|---|---|
| `#register` | `register(command_class, handler) → self` | bind a handler (any callable taking `#call(command)`) to a command class |
| `#call` | `call(command) → handler result` | dispatch; raises `UnregisteredCommand` if none |
| `#registered?` | `registered?(command_class) → bool` | is a handler bound? |

- `UnregisteredCommand < Shaolin::Error` — raised by `#call` for an unknown command (message includes the class name).
- The return value of `#call` is whatever the handler returns (handlers conventionally return a dry-monads `Result`).
- **Gotcha:** one handler per command class — a second `register` for the same class overwrites the first.
- When `Shaolin::Log.everything?` (`SHAOLIN_LOG_EVERYTHING=1`) is on, `#call` logs a `command` event with `duration_ms`, and `command_failed` on raise.

```ruby
bus = Shaolin::CQRS::CommandBus.new
bus.register(Ping, ->(cmd) { puts "ping #{cmd}" })   # lambda handler
bus.registered?(Ping)        # => true
bus.call(Ping.new)           # runs the lambda
bus.call(Pong.new)           # raises Shaolin::CQRS::UnregisteredCommand
```

## QueryBus

Symmetric read-side bus — RES has none, so this is a thin shaolin construct: one handler per query class,
returning the handler's result. No transaction, no logging of duration (just an info line under firehose).

| Method | Signature | Purpose |
|---|---|---|
| `#register` | `register(query_class, handler) → self` | bind a handler to a query class |
| `#call` | `call(query) → handler result` | dispatch; raises `UnregisteredQuery` if none |
| `#registered?` | `registered?(query_class) → bool` | is a handler bound? |

- `UnregisteredQuery < Shaolin::Error` — raised by `#call` for an unknown query.

```ruby
qbus = Shaolin::CQRS::QueryBus.new
qbus.register(FindUser, ->(q) { { id: q.id } })
qbus.call(FindUser.new(id: "u1"))   # => { id: "u1" }
```

---

## Aggregate

`module Shaolin::CQRS::Aggregate` — **include** it to make an event-sourced aggregate. On `include` it
mixes in `AggregateRoot`, giving you the `apply` (record + apply an event) and `on` (state-mutation
handler) DSL, plus `unpublished_events`, `version`, etc. Shaolin adds `attr_reader :id` and an
`initialize(id)` that stores the identity used to derive the event stream.

| Member | Signature | Purpose |
|---|---|---|
| `#id` | `id → Object` | aggregate identity (drives the stream name) |
| `#initialize` | `initialize(id)` | store id; subclasses call `super(id)` |
| `apply` (from AggregateRoot) | `apply(event)` | record an unpublished event and run its `on` handler |
| `.on` (from AggregateRoot) | `on(EventClass) { |event| ... }` | mutate `@ivars` when that event is applied |

- **Pattern:** command method emits via `apply(...)`; `on(...)` blocks set state. Never mutate state
  outside an `on` handler — that state would not survive a replay.
- Subclasses **must** call `super(id)` in their own `initialize` before setting other ivars.
- Events are plain `RubyEventStore::Event` subclasses; pass payload as `data:` (a hash).

```ruby
class Bumped < RubyEventStore::Event; end

class Counter
  include Shaolin::CQRS::Aggregate

  def initialize(id)
    super(id)
    @count = 0
  end
  attr_reader :count

  def bump = apply(Bumped.new(data: {}))
  on(Bumped) { |_e| @count += 1 }
end

c = Counter.new("c1")
c.bump; c.bump
c.count                          # => 2
c.unpublished_events.to_a.size   # => 2 (not yet persisted)
```

---

## CommandHandler

`class Shaolin::CQRS::CommandHandler` — base for write-side handlers. Declare the command with `handles`;
the `:cqrs` provider auto-registers the handler on the command bus at boot. Includes `Shaolin::Imports`
(so handlers can use `import("other.module_key")` for validated cross-module access). The aggregate
repository and event store resolve **lazily** from the kernel — so handlers stay constructible without a
booted kernel in unit tests.

| Member | Signature | Purpose |
|---|---|---|
| `.handles` | `handles(command_class) → command_class` | declare the handled command (sets `@handled_command`) |
| `.handled_command` | `handled_command → Class \| nil` | read it back (used by the wiring) |
| `#aggregate_repository` | `aggregate_repository → AggregateRepository` | resolves `Kernel["cqrs.aggregate_repository"]` |
| `#event_store` | `event_store → RubyEventStore::Client` | resolves `Kernel["cqrs.event_store"]` |

- You implement `#call(cmd)` yourself — it is not defined in the base.
- A handler with no `handles` declaration is skipped by auto-wiring.

```ruby
class RegisterUserHandler < Shaolin::CQRS::CommandHandler
  handles RegisterUser
  def call(cmd)
    aggregate_repository.unit_of_work(Users::User.new(cmd.id)) do |u|
      u.register(name: cmd.name)
    end
    Dry::Monads::Success(cmd.id)
  end
end
```

## QueryHandler

`class Shaolin::CQRS::QueryHandler` — base for read-side handlers. Declare with `handles`; the provider
auto-registers it on the query bus. Includes `Shaolin::Imports`. Query handlers read ActiveRecord read
models (the projections' output) and return data; implement `#call(query)` yourself.

| Member | Signature | Purpose |
|---|---|---|
| `.handles` | `handles(query_class) → query_class` | declare the handled query |
| `.handled_query` | `handled_query → Class \| nil` | read it back (used by the wiring) |

```ruby
class FindUserHandler < Shaolin::CQRS::QueryHandler
  handles Queries::FindUser
  def call(query) = ReadModels::UserRecord.find_by(id: query.id)
end
```

---

## Projection

`class Shaolin::CQRS::Projection` — turns events into read models. Declare handlers with `.on`; the `:cqrs`
provider subscribes the projection to those events on the event store at boot. The block runs in
**instance context** (`instance_exec`), so it can call instance helpers / write read models.

| Member | Signature | Purpose |
|---|---|---|
| `.on` | `on(event_class) { |event| ... }` | register a handler block for that event class |
| `.async` | `async → true` | mark the whole projection async (see below) |
| `.async?` | `async? → bool` | is it async? (`@async == true`) |
| `.handlers` | `handlers → Hash{Class=>Proc}` | the registered `on` blocks |
| `.subscribed_events` | `subscribed_events → Array<Class>` | `handlers.keys` |
| `#call` | `call(event)` | invoked by RES on publish; `instance_exec`s the matching block |

### sync (default) vs async

- **Sync (default):** the provider subscribes the projection synchronously, so its `on` blocks run **inside
  the event-append transaction** of `unit_of_work`. Read-your-write + atomic, at the cost of write latency.
- **Async (`async`):** the projection is **not** subscribed synchronously (`wire_projections` skips any
  `async?` projection). The `:jobs` provider drives it through the outbox; `shaolin worker` runs it,
  **at-least-once**. The read model is then **eventually consistent** (a read right after the command may
  not see it). Requires the `:jobs` provider + a running `shaolin worker`. Use for heavy / non-read-your-write
  read models.
- **Gotcha:** both paths can re-run a handler (replay; at-least-once for async) — read-model writes **must
  be idempotent upserts** that set absolute state, never `+= 1`.

```ruby
class UsersProjection < Shaolin::CQRS::Projection
  # async   # <- uncomment to run off the append tx via the outbox/worker
  on(UserRegistered) do |event|
    ReadModels::UserRecord.project(id: event.data[:id]) { |r| r.email = event.data[:email] }
  end
end
```

## ProjectionRunner

`module Shaolin::CQRS::ProjectionRunner` — rebuilds read models by replaying the event store through
projections. Because read-model writes are idempotent upserts, full replay is safe and deterministic.

| Method | Signature | Purpose |
|---|---|---|
| `.rebuild` | `rebuild(event_store, projection, after: nil) → last_event_id` | replay a single projection's events |
| `.rebuild_all` | `rebuild_all(only: nil) → void` | replay every module's projections from the kernel |
| `.containers` | `containers → Hash` | the kernel's `kernel.containers` (or `{}`) |

**`rebuild(event_store, projection, after:)`** — replays only the events the projection's `subscribed_events`
declares, read lazily in pages (bounded memory for huge streams). **Resumable:** pass `after:` (an event
id) to continue past a checkpoint; the returned value is the **last-processed event id** (use it as the next
checkpoint). Returns `after` unchanged if the projection subscribes to nothing.

```ruby
store = Shaolin::CQRS::EventStore.in_memory
e1 = Bumped2.new(data: { n: 1 })
store.publish(e1, stream_name: "X$1")
store.publish(Bumped2.new(data: { n: 2 }), stream_name: "X$2")

last = Shaolin::CQRS::ProjectionRunner.rebuild(store, RecordingProjection.new)        # replays 1, 2
# resume past a checkpoint — replays only events after e1:
Shaolin::CQRS::ProjectionRunner.rebuild(store, RecordingProjection.new, after: e1.event_id)
```

- **`rebuild_all(only:)`** — iterates `kernel.containers`; for each module's `projections.*` components calls
  `rebuild` (no checkpoint). `only: "users"` (String or Symbol) restricts to one module. This backs
  `shaolin projections rebuild [NAME]`.
- **Gotcha:** `rebuild` replays into the projection live — point it at a fresh/empty read model (or
  truncate first) to avoid stale rows lingering, and run it against a single projection at a time when you
  need a checkpoint (`rebuild_all` does not checkpoint).

---

## EventStore

`module Shaolin::CQRS::EventStore` — factory for the `RubyEventStore::Client`.

| Method | Signature | Purpose |
|---|---|---|
| `.in_memory` | `in_memory → RubyEventStore::Client` | client over `RubyEventStore::InMemoryRepository` |
| `.build` | `build(repository:, mapper: nil) → RubyEventStore::Client` | wrap an injected repository |

- `in_memory` is for tests and monolith/dev before a durable backend is registered.
- `build(repository:, mapper:)` wraps an injected repository (the AR-backed one in prod, supplied via
  `cqrs.event_store_backend`).
- **`mapper:` is the event-versioning / upcasting seam.** Pass a `RubyEventStore::Mappers::PipelineMapper`
  whose transformations include `Transformation::Upcast.new(...)`; old event versions are rewritten to the
  current shape on read. `nil` (default) uses RES's default mapper. The provider sources it from the
  optional kernel key `cqrs.event_mapper`. See `docs/EVENTS.md`.

```ruby
store = Shaolin::CQRS::EventStore.in_memory
store.publish(UserRegistered.new(data: { id: "u1" }), stream_name: "Users::User$u1")
store.read.of_type([UserRegistered]).each { |e| p e.data }

# Durable + upcasting:
Shaolin::CQRS::EventStore.build(repository: ar_repo, mapper: upcasting_pipeline)
```

---

## AggregateRepository

`class Shaolin::CQRS::AggregateRepository` — loads and stores event-sourced aggregates, deriving the stream
name from the aggregate's class + id (callers never build stream names by hand). Wraps
`AggregateRoot::Repository` (transactional, optimistic concurrency).

| Method | Signature | Purpose |
|---|---|---|
| `#initialize` | `initialize(event_store, transaction: nil)` | wrap a store; optional tx runner |
| `#unit_of_work` | `unit_of_work(aggregate) { |aggregate| ... } → block result` | load, yield for mutation, persist new events |
| `#load` | `load(aggregate_class, id) → aggregate` | rebuild an aggregate by replay |

### `unit_of_work` — the atomic transactional outbox

`unit_of_work(aggregate, &block)` derives the stream (`CQRS.stream_name`), then runs
`@repository.with_aggregate(aggregate, stream, &block)` — **inside the transaction runner if one is set**.

- The `transaction:` runner is an optional callable taking a block. The `:active_record` provider registers
  one as `cqrs.transaction`; the `:cqrs` provider passes it here. When present, the **whole** unit of work —
  event append **+ synchronous subscribers (sync projections AND the outbox enqueue)** — runs in **one DB
  transaction**. That is what makes the transactional outbox atomic: a crash can never persist an event
  without its outbox row.
- **Without** a runner (e.g. the in-memory store), the block runs directly — still correct, just not atomic
  across a real DB.
- **`load`** replays the full stream into a fresh `aggregate_class.new(id)`; use it to reconstruct current
  state (e.g. for invariants) outside a write.

```ruby
repo = Shaolin::CQRS::AggregateRepository.new(Shaolin::CQRS::EventStore.in_memory)

repo.unit_of_work(Accumulator.new("a1")) do |acc|
  acc.add(3)
  acc.add(4)
end
repo.load(Accumulator, "a1").total   # => 7  (rebuilt purely from events)
```

## stream_name

`Shaolin::CQRS.stream_name(aggregate_class, id) → String` — canonical event-stream name for an aggregate
instance: `"<AggregateClass>$<id>"` (e.g. `"Users::User$u1"`). Centralized so stream names are never
hand-built; used internally by `AggregateRepository`.

```ruby
Shaolin::CQRS.stream_name(Users::User, "u1")   # => "Users::User$u1"
```

---

## The `:cqrs` provider wiring

`Shaolin::CQRS.register_provider!` registers the `:cqrs` lifecycle provider. Its `start` block, at boot:

1. Reads optional `cqrs.event_mapper` (upcasting). Builds the event store: `EventStore.build(repository:
   cqrs.event_store_backend, mapper:)` **if** `cqrs.event_store_backend` is registered (AR in prod),
   else `EventStore.in_memory` (monolith/dev/test).
2. Builds `CommandBus` + `QueryBus`; registers `cqrs.event_store`, `cqrs.command_bus`, `cqrs.query_bus`.
3. Reads optional `cqrs.transaction` and registers `cqrs.aggregate_repository` =
   `AggregateRepository.new(event_store, transaction:)`.
4. Under `SHAOLIN_LOG_EVERYTHING`, subscribes a firehose logger to **all** events (`event` log line).
5. Calls `wire_modules(command_bus, query_bus, event_store)`.

**`wire_modules`** iterates `kernel.containers` and, per module container:

| Helper | Convention | Effect |
|---|---|---|
| `wire_command_handlers` | components keyed `command_handlers.*` | `command_bus.register(handler.class.handled_command, handler)` (skips if no `handled_command`) |
| `wire_query_handlers` | components keyed `query_handlers.*` | `query_bus.register(handler.class.handled_query, handler)` (skips if no `handled_query`) |
| `wire_projections` | components keyed `projections.*` | `event_store.subscribe(projection, to: subscribed_events)` — **skips `async?` projections** (the `:jobs` provider wires those via the outbox) and skips empty subscriptions |

So in a generated app you just drop a `CommandHandler`/`QueryHandler`/`Projection` (with `handles`/`on`)
into the module's `command_handlers/`, `query_handlers/`, `projections/` folders — wiring is automatic.

```ruby
Shaolin::CQRS.register_provider!
app = Shaolin::App.new(root: root).boot!

# Per-module containers expose the shared buses (resolved from the kernel):
app["users"]["cqrs.command_bus"].call(RegisterUser.new(id: "u1", name: "Jane"))
app["users"]["cqrs.query_bus"].call(FindUser.new(id: "u1"))
```

---

## Options, kwargs, ENV & gotchas

| Surface | Detail |
|---|---|
| `EventStore.build(repository:, mapper: nil)` | `mapper` nil → RES default; non-nil → upcasting pipeline |
| `AggregateRepository.new(event_store, transaction: nil)` | `transaction` nil → no atomic wrapping (in-memory ok) |
| `ProjectionRunner.rebuild(es, projection, after: nil)` | `after` event-id checkpoint; returns last-processed id |
| `ProjectionRunner.rebuild_all(only: nil)` | `only` String/Symbol module name filter |
| `Projection.async` | opt a projection out of the sync append tx (needs `:jobs` + worker) |
| Kernel keys read | `cqrs.event_store_backend`, `cqrs.event_mapper`, `cqrs.transaction`, `kernel.containers` (all optional) |
| Kernel keys published | `cqrs.event_store`, `cqrs.command_bus`, `cqrs.query_bus`, `cqrs.aggregate_repository` |
| `SHAOLIN_LOG_EVERYTHING=1` | firehose: log every command (`+duration_ms`), query, and domain event |

**Gotchas**
- One handler per command/query class; re-registering overwrites.
- Mutate aggregate state **only** inside `on` handlers (else it won't survive replay); always `super(id)`.
- Projections and async reactors run at-least-once → **idempotent upserts only**.
- `unit_of_work` is atomic only when a `cqrs.transaction` runner is present (i.e. with `:active_record`); the
  in-memory store is not transactional across a real DB.
- `rebuild_all` does not checkpoint — use single-projection `rebuild(after:)` for resumable huge-stream replays.
- Handlers/projections without `handles`/`on` are silently skipped by auto-wiring.

# shaolin-cqrs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. TDD, small files, commit per task. Run `cd gems/shaolin-cqrs && bundle exec rspec`.

**Goal:** The CQRS/ES building blocks: canonical stream naming, an aggregate base, command bus, query bus, an event-store factory, and an aggregate repository — over verified ruby_event_store 2.19.2 / aggregate_root 2.19.2 / arkency-command_bus 0.4.1.

**Architecture:** Thin shaolin wrappers over RES primitives, plus a `:cqrs` provider that registers the shared services and a kernel shared-container so any module can resolve `cqrs.*` via `Deps`. Transport-agnostic: HTTP/Kafka adapters only produce commands / carry events.

**Verified APIs (probed 2026-06-03):**
- `RubyEventStore::Client.new(repository: RubyEventStore::InMemoryRepository.new)`; `client.subscribe(callable, to: [EventClass])`.
- Aggregate: `include AggregateRoot`; `apply(Event.new(data:))`; class macro `on EventClass do |e| … end`.
- `AggregateRoot::Repository.new(event_store)`; `.with_aggregate(agg, stream){ |a| … }`; `.load(agg, stream)`.
- `Arkency::CommandBus.new`; `.register(CommandClass, ->(cmd){ … })`; `.call(cmd)`.

---

## File Structure

```
gems/shaolin-cqrs/lib/shaolin/cqrs.rb           # entrypoint + requires
  lib/shaolin/cqrs/stream_name.rb               # Shaolin::CQRS.stream_name
  lib/shaolin/cqrs/aggregate.rb                 # Shaolin::CQRS::Aggregate (includes AggregateRoot + id)
  lib/shaolin/cqrs/command_bus.rb               # wraps Arkency::CommandBus
  lib/shaolin/cqrs/query_bus.rb                 # symmetric query routing
  lib/shaolin/cqrs/event_store.rb               # factory (in-memory + injected backend)
  lib/shaolin/cqrs/aggregate_repository.rb      # wraps AggregateRoot::Repository, derives stream
  lib/shaolin/cqrs/provider.rb                  # registers :cqrs provider + cqrs.* services
```

## Task 1: stream_name
- [ ] Test: `Shaolin::CQRS.stream_name(Users::User, "u1")` => `"Users::User$u1"`; works for any class+id.
- [ ] Impl: `"#{aggregate_class.name}$#{id}"`.
- [ ] Commit.

## Task 2: Aggregate base
- [ ] Test: a class `include Shaolin::CQRS::Aggregate` gains AggregateRoot (`apply`, `on`) and stores `id`.
- [ ] Impl: module that on `included` does `base.include(AggregateRoot)`; provide `#id` reader set via `initialize(id)` convention (document that aggregates call `super(id)`).
- [ ] Commit.

## Task 3: CommandBus
- [ ] Test: register a command class with a handler responding to `#call`; dispatching routes to it; unknown command raises a clear error.
- [ ] Impl: wrap `Arkency::CommandBus`; `register(klass, handler)` where handler is callable; `call(cmd)`; raise `Shaolin::CQRS::UnregisteredCommand` (a `Shaolin::Error`) if missing.
- [ ] Commit.

## Task 4: QueryBus
- [ ] Test: symmetric to CommandBus for queries.
- [ ] Impl: thin map of query class -> handler; `call(query)`.
- [ ] Commit.

## Task 5: EventStore factory
- [ ] Test: `Shaolin::CQRS::EventStore.in_memory` returns a working `RubyEventStore::Client`; publish + subscribe roundtrip.
- [ ] Impl: `in_memory` builds client with InMemoryRepository; `build(repository:)` for injected backends.
- [ ] Commit.

## Task 6: AggregateRepository
- [ ] Test: `repo.unit_of_work(User.new("u1")) { |u| u.register(...) }` persists events; `repo.load(User, "u1")` rebuilds; stream derived via stream_name.
- [ ] Impl: wrap `AggregateRoot::Repository`; derive stream from `agg.class` + `agg.id`; expose `unit_of_work(agg, &blk)` and `load(klass, id)`.
- [ ] Commit.

## Task 7: Kernel shared container (core extension)
- [ ] Test (in shaolin-core): a provider can register a shared component; every ModuleContainer resolves it (fallback) unless shadowed locally.
- [ ] Impl: add `Shaolin.kernel` shared registry; `ModuleContainer#[]` falls back to kernel for infra keys after local + imports, before raising IsolationError (infra keys namespaced, e.g. `cqrs.*`, are allowed globally).
- [ ] Commit (note: modifies shaolin-core; re-run its suite).

## Task 8: :cqrs provider
- [ ] Test: registering the `:cqrs` provider and booting makes `cqrs.command_bus`, `cqrs.query_bus`, `cqrs.event_store`, `cqrs.aggregate_repository` resolvable from a module via `Deps`.
- [ ] Impl: `Shaolin.register_provider(:cqrs) { start { register cqrs.* into kernel shared container } }`; event-store backend injected (defaults to in-memory if none registered, e.g. before shaolin-activerecord).
- [ ] Commit.

## Task 9: README + green suite
- [ ] README documenting commands/events/aggregates/handlers/projections workflow.
- [ ] Full suite green; merge to master.

## Definition of Done
- All green; no file > ~150 lines; APIs verified against installed gems; errors expose `#to_contract`.

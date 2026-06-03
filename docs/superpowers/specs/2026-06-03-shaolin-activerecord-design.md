# shaolin-activerecord — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** [shaolin-core](2026-06-03-shaolin-core-design.md), [shaolin-cqrs](2026-06-03-shaolin-cqrs-design.md)
**Sub-project:** 3 of 10 (persistence)

## 1. Purpose

`shaolin-activerecord` integrates **ActiveRecord** in its **two shaolin roles**:

1. **Event-store backend** — the AR-backed repository that `shaolin-cqrs` injects into its
   `RubyEventStore::Client`.
2. **Read-model / projection store** — per-module AR read models plus an idempotent upsert API
   that projections call.

It also owns standalone AR setup (no Rails), the **fiber-safe connection pool** configuration for
Falcon's async-first default, and **per-module migrations**.

## 2. Foundation (verified 2026-06-03)

- **Event-store repository:** `RubyEventStore::ActiveRecord::EventRepository.new(serializer:)` —
  tables `event_store_events` + `event_store_events_in_streams`; serializers YAML (default) or
  JSON (jsonb). PostgreSQL-optimized **`RubyEventStore::ActiveRecord::PgLinearizedEventRepository`**
  uses advisory locks for a linearized global order under concurrency. The
  `RubyEventStore::ActiveRecord` adapter ships a rake task to generate/run the event-store
  migration **without Rails**.
- **Standalone AR:** `ActiveRecord::Base.establish_connection(adapter:, host:, …)` (or
  `DATABASE_URL`). No Rails runtime required — AR 8.x used as a library.
- **Fiber-safe pool:** AR's connection pool is fiber-safe and honors an isolation level; under
  Falcon set fiber isolation so each request-fiber checks out its own connection. (In Rails this is
  `config.active_support.isolation_level = :fiber`; the standalone equivalent is the underlying
  `ActiveSupport::IsolatedExecutionState.isolation_level = :fiber` — exact API confirmed at planning.)

## 3. Decisions

- **Default DB: PostgreSQL.** Use the **JSON (jsonb)** serializer for events (queryable payloads)
  and the **`PgLinearizedEventRepository`** for safe, linearized event ordering under concurrent
  writers — aligns with the async-first Falcon default.
- **Read models are plain AR models** living in each module's `read_models/` folder; they are
  *projection-owned* (only the module's projections write them).
- **Two migration tracks:** (a) the RES event-store schema (once, app-wide); (b) per-module
  read-model migrations.

## 4. Connection & pool (12-factor, async-first)

- Configured from ENV (`DATABASE_URL` or discrete vars) via shaolin-core config.
- On boot (provider `start`), `establish_connection` runs once; pool size derived from server
  concurrency (documented formula: fibers/threads per process + RES dispatcher headroom + 1).
- Under Falcon: fiber isolation enabled so connections are checked out per request-fiber; `pg`
  build supporting concurrent queries. Under Puma: thread isolation (default).
- Connections are returned/closed on graceful shutdown (hook into shaolin-server lifecycle).

## 5. Event-store backend (handoff to shaolin-cqrs)

- Provides `Shaolin::AR.event_repository(config)` returning a configured
  `PgLinearizedEventRepository` (JSON serializer).
- Registered in the app container as `cqrs.event_store_backend`; `shaolin-cqrs`'s provider
  consumes it to build the `RubyEventStore::Client`. This keeps the dependency direction clean:
  cqrs declares the *port*, activerecord supplies the *adapter*.

## 6. Read models & the projection write API

- Read-model base: a thin module/mixin on top of `ActiveRecord::Base` (`Shaolin::AR::ReadModel`)
  adding an **idempotent upsert keyed by aggregate id** so projections are safe to replay:

  ```ruby
  class UserRecord < Shaolin::AR::ReadModel
    self.table_name = "users_read"
  end

  # called by a projection
  UserRecord.project(id: event.data[:id]) do |r|
    r.email = event.data[:email]
    r.name  = event.data[:name]
  end   # upsert: insert or update by id, idempotent on replay
  ```

- `project(id:) { |record| … }` performs an `upsert` (Postgres `ON CONFLICT`) so rebuilding a
  projection from the event stream is deterministic and safe.

## 7. Migrations

- **Event store:** a `shaolin db:create_event_store` task wraps the RES AR generator/migration to
  install `event_store_events` + `event_store_events_in_streams` (jsonb columns).
- **Per-module read models:** migrations live in `app/modules/<m>/db/migrate/` (module-local, so a
  module is self-contained and agent-ownable). A migrator aggregates and runs them in order.
- CLI surface (implemented in shaolin-cli): `shaolin db:migrate`, `shaolin db:rollback`,
  `shaolin db:create_event_store`. Migrations run in the container entrypoint before server start.

## 8. Kernel integration (provider)

```ruby
Shaolin.register_provider(:active_record) do
  start do
    # establish_connection from ENV; set isolation level (:fiber under Falcon / :thread under Puma);
    # register cqrs.event_store_backend (PgLinearizedEventRepository, JSON);
    # register the read-model base + migrator.
  end
  stop { # disconnect pool }
end
```

Ordering: this provider starts **before** the `:cqrs` provider (cqrs needs the event-store
backend). shaolin-core's provider ordering guarantees this via declared dependencies.

## 9. Public API

- `Shaolin::AR.event_repository(config)` — configured event-store repository.
- `Shaolin::AR::ReadModel` — read-model base with `.project(id:) { |r| … }` idempotent upsert.
- `Shaolin::AR::Migrator` — module-aware migration runner.
- Container keys: `cqrs.event_store_backend`, `ar.connection`, `ar.migrator`.

## 10. Error handling

- **Connection failure at boot** → fail fast with a clear message (DB unreachable / bad creds).
- **Migration pending in production** → refuse to start (configurable), surfacing which module's
  migration is missing.
- **Projection upsert conflict** → handled by `ON CONFLICT` upsert (idempotent), never a crash on
  replay.

## 11. Testing strategy

- Transactional test DB; per-test truncation for projection tests.
- In-memory/SQLite path for fast unit tests where the linearized PG repo isn't needed (event-store
  semantics still validated against PG in integration tests).
- Read-model tests assert idempotency: applying the same event twice yields one row, unchanged.
- RSpec; TDD.

## 12. To verify during planning

- ActiveRecord 8.x standalone API on Ruby 4.0 (establish_connection, pool config, executor).
- Exact standalone fiber-isolation setting (`ActiveSupport::IsolatedExecutionState.isolation_level`
  vs a config shim) under Falcon, and pool-size formula.
- RES AR adapter's non-Rails migration rake task name/signature and jsonb migration for
  `PgLinearizedEventRepository`.
- `pg` gem version with concurrent-query support compatible with the fiber scheduler.
- Whether read-model migrations should reuse AR's `Migration` DSL directly or a thin wrapper.

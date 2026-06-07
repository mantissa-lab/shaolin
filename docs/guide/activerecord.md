# ActiveRecord: event store, read models, migrations, replica

`shaolin-activerecord` is the standalone ActiveRecord integration (no Rails) that backs the
write side (durable Postgres event store + atomic transactional outbox) and the read side
(projection read models, per-module migrations). One require pulls it all in:

```ruby
require "shaolin/activerecord"
```

That loads `Shaolin::AR::{Connection, EventStoreSchema, ReadModel, Migrator, Provider}`,
`Shaolin::AR.event_repository`, and `Shaolin::Testing`. Everything is namespaced under
`Shaolin::AR` except the test helper, which is `Shaolin::Testing`.

Gem version constant: `Shaolin::ActiveRecordIntegration::VERSION` (`"0.1.0"`).

> Postgres only. The repository, advisory locks, and replica routing all assume PostgreSQL.

---

## `Shaolin::AR::Connection`

Establishes the standalone AR connection and sets the concurrency isolation level
(`:fiber` under Falcon, `:thread` under Puma). All methods are module methods.

### `Connection.establish!(config, replica: nil)`

Connect using a plain hash config. Missing pool keys get production-safe defaults from ENV.
Returns the `Connection` module itself.

| arg / kwarg | default | meaning |
|---|---|---|
| `config` | — | adapter/database/host/... hash (string or symbol keys; keys are symbolized) |
| `replica:` | `nil` | optional replica config hash; when present, wires AR multi-DB role routing |

Defaults merged into both primary and replica configs:

| key | ENV var | default |
|---|---|---|
| `pool` | `DB_POOL` | `5` (must be ≥ concurrent fibers/threads hitting the DB) |
| `checkout_timeout` | `DB_CHECKOUT_TIMEOUT` | `5.0` (seconds) |
| `reaping_frequency` | `DB_REAPING_FREQUENCY` | `60` (seconds; reclaims leaked connections) |

Behavior:
- **No `replica:`** — plain single-DB `establish_connection(primary)`.
- **With `replica:`** — sets `ActiveRecord::Base.configurations` to `{ env => { "primary" => ..., "replica" => ... } }`
  and calls `connects_to(database: { writing: :primary, reading: :replica })`. All writes (event
  append, sync projections, outbox enqueue) stay on the **writing** role / primary, so the atomic
  outbox is unaffected; only `Shaolin::AR.reading { ... }` blocks route to the replica.

```ruby
config = { adapter: "postgresql", database: "app_prod", host: "/tmp", port: 5432 }
Shaolin::AR::Connection.establish!(config)                       # single DB
Shaolin::AR::Connection.establish!(config, replica: replica_cfg) # primary + read replica
```

> Gotcha: `pool` must be ≥ the number of concurrent workers (e.g. `worker --threads N`) or
> threads will block on `checkout_timeout` then raise `ConnectionTimeoutError`.

### `Connection.reading(&block)`

Route a block's queries to the read replica (when configured). A **no-op passthrough** when no
replica is wired, so app code can wrap heavy/analytical reads unconditionally. Returns the block's
value.

```ruby
Shaolin::AR::Connection.reading do
  ReadModels::BigReport.where(stage: "offer").to_a
end
# Without a replica: runs against the single DB, identical result.
```

There's a top-level convenience alias: `Shaolin::AR.reading(&block)` delegates to this.

### `Connection.with_advisory_lock(key)`

Serialize a critical section across processes/replicas via a Postgres **session** advisory lock
(`pg_advisory_lock` / `pg_advisory_unlock`). Blocks until the lock is held, runs the block, then
releases it in an `ensure`. `key` is coerced with `key.to_i`. Used for one-time boot schema creation.

```ruby
Shaolin::AR::Connection.with_advisory_lock(7_283_010) do
  Shaolin::AR::EventStoreSchema.create!
end
```

### `Connection.connected?`

Returns `true` if `SELECT 1` succeeds, `false` on any `StandardError`. Used as the `"database"`
health check.

```ruby
Shaolin::AR::Connection.connected? # => true
```

### `Connection.isolation_level=(level)` / `Connection.isolation_level`

Set/read `ActiveSupport::IsolatedExecutionState.isolation_level`. `level` is `:fiber` (Falcon /
async) or `:thread` (Puma). The setter chooses how AR scopes per-connection state.

```ruby
Shaolin::AR::Connection.isolation_level = :fiber
Shaolin::AR::Connection.isolation_level # => :fiber
```

---

## `Shaolin::AR::ReadModel`

Abstract `ActiveRecord::Base` subclass (`self.abstract_class = true`) for projection read models.
Subclass it and set `table_name`.

### `ReadModel.project(id:) { |record| ... }`

Idempotent upsert keyed by the aggregate id (the model's `primary_key`). Does
`find_or_initialize_by(primary_key => id)`, yields the record to the block, then `save!` and returns
the record. Because re-projecting the same id updates the **same** row, replaying an event stream to
rebuild a read model is deterministic.

```ruby
class UsersRead < Shaolin::AR::ReadModel
  self.table_name = "users_read"
end

UsersRead.project(id: "u1") { |r| r.email = "a@b.c" }   # INSERT
UsersRead.project(id: "u1") { |r| r.email = "new@b.c" } # UPDATE same row
UsersRead.count                # => 1
UsersRead.find("u1").email     # => "new@b.c"
```

> Gotcha: projections should set **absolute** state, not increment (`r.count += 1`), or a replay
> won't be deterministic. The primary key column must be the aggregate id (use `id: false` +
> `t.string :id` + add the primary key, as in the specs).

---

## `Shaolin::AR::EventStoreSchema`

Creates/drops the RubyEventStore event-store schema standalone (no Rails) via the gem's
`DatabaseAdapter` + `MigrationGenerator`. All methods are module methods.

Constant: `EventStoreSchema::TABLES = %w[event_store_events_in_streams event_store_events]`.

### `EventStoreSchema.create!(data_type: "binary")`

Idempotently create the event-store tables. Returns early (`nil`) if `exists?`. Otherwise generates
the gem migration for the current adapter and `data_type`, evals it, and runs it with messages
suppressed.

| kwarg | default | meaning |
|---|---|---|
| `data_type:` | `"binary"` | column type for serialized event data; `binary` gives robust symbol-key round-trip with the YAML serializer |

```ruby
Shaolin::AR::EventStoreSchema.create!  # creates event_store_events + ..._in_streams
Shaolin::AR::EventStoreSchema.create!  # no-op (idempotent)
```

> Gotcha: it `remove_const(:CreateEventStoreEvents)` then re-defines and `eval`s the generated
> migration class. This is fine for boot, but don't define your own top-level `CreateEventStoreEvents`.

### `EventStoreSchema.drop!`

Drop both tables (`force: :cascade`) if they exist. Returns the iterated `TABLES`.

### `EventStoreSchema.exists?`

`true` if `event_store_events` exists.

### `EventStoreSchema.adapter_name`

The current connection's adapter name, downcased (e.g. `"postgresql"`). Used internally to pick the
`DatabaseAdapter`.

---

## `Shaolin::AR.event_repository`

The durable event-store backend injected into shaolin-cqrs.

### `Shaolin::AR.event_repository(serializer: RubyEventStore::Serializers::YAML)`

Returns a `RubyEventStore::ActiveRecord::PgLinearizedEventRepository` — the PostgreSQL-linearized
repository (advisory locks → a consistent **global** event order under concurrent writers) using the
YAML serializer by default.

| kwarg | default | meaning |
|---|---|---|
| `serializer:` | `RubyEventStore::Serializers::YAML` | event (de)serializer; YAML preserves symbol keys incl. nested |

```ruby
Shaolin::AR::EventStoreSchema.create!
client = RubyEventStore::Client.new(repository: Shaolin::AR.event_repository)

stub_const("Probed", Class.new(RubyEventStore::Event))
client.publish(Probed.new(data: { msg: "hi", n: 2 }), stream_name: "Probe$1")
client.read.stream("Probe$1").to_a.first.data # => { msg: "hi", n: 2 } (symbol keys preserved)
```

---

## `Shaolin::AR::Migrator`

Runs per-module read-model migrations found under `app/modules/*/db/migrate/`. Each module keeps its
own migrations so it stays self-contained. Adds Flyway/Rails-style **drift detection**. All methods
are module methods.

Constant: `Migrator::CHECKSUM_TABLE = "shaolin_migration_checksums"`.

### `Migrator.run(modules_dir)`

Migrate all unapplied per-module migrations under `modules_dir`. Sequence:
1. Build a `MigrationContext` over every existing `*/db/migrate` dir (returns early / `nil` if none).
2. Ensure the `shaolin_migration_checksums` table exists.
3. **`check_drift!`** — raise `Shaolin::Error` BEFORE migrating if an already-applied migration file changed on disk.
4. `context.migrate` (messages suppressed).
5. Record checksums for all files (`ON CONFLICT (version) DO NOTHING` — blesses each version's content once).

```ruby
Shaolin::AR::Migrator.run("app/modules")
ActiveRecord::Base.connection.table_exists?("widgets_read") # => true
```

Drift error (raised when an applied migration's file is edited):

```
migration drift detected — these applied migrations changed on disk:
  20260603000001_create_widgets_read.rb
An applied migration must never be edited: ...
  dev:  `shaolin db reset` (re-applies from scratch), then re-edit freely
  prod: revert the edit and add a NEW migration for the change
```

> Gotcha: editing an **unapplied** migration is allowed (its checksum was never blessed). Only files
> whose version is already in `schema_migrations` **and** has a stored checksum are guarded.

### `Migrator.rollback(modules_dir, steps = 1)`

Roll back the last `steps` applied migrations across all modules (messages suppressed). Returns early
(`nil`) if there's no migration context.

```ruby
Shaolin::AR::Migrator.rollback("app/modules", 2) # undo last two
```

### Internal/supporting methods (also public module methods)

| method | purpose |
|---|---|
| `context_for(modules_dir)` | `MigrationContext` over sorted existing `*/db/migrate` dirs, or `nil` |
| `check_drift!(files)` | raise `Shaolin::Error` if any applied file's checksum differs from stored |
| `migration_files(modules_dir)` | sorted `*/db/migrate/*.rb` paths |
| `version_of(file)` | leading digits of the basename (the migration version), or `nil` |
| `checksum(file)` | `Digest::SHA256.hexdigest(File.read(file))` |
| `applied_versions` | `schema_migrations.version` values as strings (`[]` if table missing) |
| `stored_checksums` | `{ version => checksum }` from the checksum table |
| `record_checksums!(files)` | insert each version's checksum once (`ON CONFLICT DO NOTHING`) |
| `ensure_checksum_table!` | create `shaolin_migration_checksums (version, checksum)` + unique index on `version` |

---

## `:active_record` provider

`Shaolin::AR.register_provider!` registers the `:active_record` Kernel provider: it connects,
optionally creates the event-store schema, registers a health check, and publishes the durable
backend + transaction runner into the Kernel.

Constant: `Shaolin::AR::SCHEMA_LOCK_KEY = 7_283_010` (the advisory-lock key guarding boot schema creation).

### `Shaolin::AR.register_provider!(config:, isolation_level: :thread, auto_schema: true, replica_config: nil)`

| kwarg | default | meaning |
|---|---|---|
| `config:` | — (required) | primary DB hash passed to `Connection.establish!` |
| `isolation_level:` | `:thread` | `:thread` (Puma) or `:fiber` (Falcon) |
| `auto_schema:` | `true` | create the event-store schema at boot, advisory-locked; **set `false` in prod** and run migrations as a release step |
| `replica_config:` | `nil` | optional replica hash; enables `Shaolin::AR.reading` routing |

On `start` the provider:
1. `Connection.establish!(config, replica: replica_config)`
2. `Connection.isolation_level = isolation_level`
3. if `auto_schema`: `Connection.with_advisory_lock(SCHEMA_LOCK_KEY) { EventStoreSchema.create! }`
4. `Shaolin::Health.register("database") { Connection.connected? }`
5. `Shaolin::Kernel.register("cqrs.event_store_backend", Shaolin::AR.event_repository)` — the `:cqrs` provider wraps this
6. `Shaolin::Kernel.register("cqrs.transaction", ->(&blk) { ActiveRecord::Base.transaction(&blk) })` — the transaction runner that makes the outbox atomic (append + sync subscribers commit as one)

On `stop`: `ActiveRecord::Base.connection_handler.clear_all_connections!` (errors swallowed).

```ruby
# Order matters: register :active_record BEFORE :cqrs so the durable backend is
# present when cqrs boots (otherwise cqrs falls back to in-memory).
Shaolin::AR.register_provider!(config: PG_CONFIG)            # dev/test: auto_schema on
Shaolin::CQRS.register_provider!
Shaolin::Provider.start_all

Shaolin::Kernel["cqrs.event_store_backend"] # => PgLinearizedEventRepository
Shaolin::Kernel["cqrs.event_store"].publish(ThingHappened.new(data: { v: 1 }), stream_name: "Thing$1")
```

```ruby
# production: schema managed by a release step, not at boot
Shaolin::AR.register_provider!(config: PG_CONFIG, auto_schema: false, isolation_level: :fiber)
```

> Gotcha: with `auto_schema: false`, run `shaolin migrate` (which drives `Migrator.run` / schema
> creation) as a deploy step, or the event-store tables won't exist.

---

## `Shaolin::Testing`

DatabaseCleaner-style test isolation (opt-in). `module_function`, so call on the module.

Constant: `Testing::PRESERVE = %w[schema_migrations ar_internal_metadata]` — AR bookkeeping tables
that are never truncated.

### `Shaolin::Testing.clean!`

`TRUNCATE ... RESTART IDENTITY CASCADE` every app table (read models, event store, AND the jobs
outbox/schedules) except `PRESERVE`. Tables are **truncated, not dropped**. No-op if there are no
app tables.

```ruby
Shaolin::Testing.clean! # wipe all rows + reset identity, keep schema_migrations
```

> Gotcha: this prevents a stale `pending` outbox job from a prior example firing in a later one.

### `Shaolin::Testing.install(rspec_config, only: nil)`

Register a `before(:each)` that calls `clean!`. `only:` scopes it to an RSpec metadata tag (e.g.
`:integration`) so DB-less unit specs stay fast; without it, every example is cleaned.

| arg / kwarg | default | meaning |
|---|---|---|
| `rspec_config` | — | the RSpec config object |
| `only:` | `nil` | metadata tag filter; `nil` = all examples, `:integration` = `{ integration: true }` only |

```ruby
# spec_helper.rb
RSpec.configure do |config|
  Shaolin::Testing.install(config, only: :integration)
end

# only this example gets a clean DB:
it "does a thing", :integration do
  # ...
end
```

---

## ENV var reference

| ENV | used by | default |
|---|---|---|
| `DB_POOL` | `Connection.establish!` pool size | `5` |
| `DB_CHECKOUT_TIMEOUT` | `Connection.establish!` checkout wait (s) | `5.0` |
| `DB_REAPING_FREQUENCY` | `Connection.establish!` reaping (s) | `60` |

The connection **config hash** (adapter/database/username/password/host/port) is supplied by you /
your app config, not read from ENV by this gem (the specs' `PgTest::CONFIG` reads `DB_NAME`,
`DB_USER`, `PGPASSWORD`, `DB_HOST`, `DB_PORT`, but that is test scaffolding, not gem behavior).

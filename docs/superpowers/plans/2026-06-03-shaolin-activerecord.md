# shaolin-activerecord Implementation Plan


> **STATUS: ✅ COMPLETE (2026-06-03).** 8 examples vs live PostgreSQL 15.4; durable event store integrates with :cqrs end-to-end. Verified AR 8.1.3 / pg 1.6.3 / ruby_event_store-active_record 2.19.2. Merged to master.
> REQUIRED SUB-SKILL: superpowers:executing-plans. TDD, small files, commit per task. Tests run against local PG (port 5433, socket /tmp, db shaolin_test). Run `cd gems/shaolin-activerecord && bundle exec rspec`.

**Goal:** ActiveRecord integration — the durable event-store backend (injected into cqrs), a read-model base with idempotent projection upsert, per-module migrations, standalone connection with fiber/thread isolation, and the `:active_record` provider.

**Verified APIs (probed 2026-06-03, AR 8.1.3 / ruby_event_store-active_record 2.19.2):**
- `ActiveRecord::Base.establish_connection(adapter: "postgresql", database:, username:, host:, port:)` (hash config; URL form rejected by uri 1.1.1 for socket).
- Schema standalone: `da = RubyEventStore::ActiveRecord::DatabaseAdapter.from_string("postgresql", "binary")`; `_p, code = RubyEventStore::ActiveRecord::MigrationGenerator.new.generate(da, "/tmp")`; `eval(code)`; `ActiveRecord::Migration.suppress_messages { CreateEventStoreEvents.migrate(:up) }`.
- Backend: `RubyEventStore::ActiveRecord::PgLinearizedEventRepository.new(serializer: RubyEventStore::Serializers::YAML)` — **binary + YAML** chosen (robust symbol-key round-trip; jsonb+JSON loses symbol keys). Linearized ordering via PG advisory locks.

---

## File Structure
```
gems/shaolin-activerecord/lib/shaolin/activerecord.rb        # entrypoint
  lib/shaolin/ar/connection.rb         # establish_connection from config + isolation level
  lib/shaolin/ar/event_store_schema.rb # create!/drop! RES tables standalone
  lib/shaolin/ar/event_repository.rb   # Shaolin::AR.event_repository -> PgLinearized
  lib/shaolin/ar/read_model.rb         # AR base + project(id:){} idempotent upsert
  lib/shaolin/ar/migrator.rb           # run per-module read-model migrations
  lib/shaolin/ar/provider.rb           # :active_record provider; registers cqrs.event_store_backend
spec/support/pg.rb                     # connect + reset schema between tests
```

## Task 1: Connection
- [ ] Test: `Shaolin::AR::Connection.establish!(config)` connects (hash from ENV); `connected?` true; sets isolation level.
- [ ] Impl: parse ENV (SHAOLIN_TEST_DATABASE_URL or discrete) into a hash; `establish_connection`; set `ActiveSupport::IsolatedExecutionState.isolation_level` (:fiber for falcon / :thread default) — verify exact setter; commit.

## Task 2: EventStoreSchema
- [ ] Test: `create!` builds `event_store_events` + `event_store_events_in_streams`; `drop!` removes them; idempotent (create! when present is a no-op).
- [ ] Impl: use DatabaseAdapter + MigrationGenerator (verified flow), binary data_type; commit.

## Task 3: event_repository
- [ ] Test: `Shaolin::AR.event_repository` returns a PgLinearizedEventRepository; a RubyEventStore::Client over it publishes + reads (symbol round-trip).
- [ ] Impl: build PgLinearized(serializer: YAML); commit.

## Task 4: ReadModel base
- [ ] Test: `UserRecord.project(id: "u1"){ |r| r.email = "a@b.c" }` inserts; calling again with same id updates (one row); arbitrary read-model table.
- [ ] Impl: abstract AR base; `project(id:)` find_or_initialize_by(primary_key) + yield + save!; commit.

## Task 5: Migrator
- [ ] Test: given a tmp module with `db/migrate/*_create_*.rb`, `Migrator.run(modules_dir)` creates the read-model table.
- [ ] Impl: collect `app/modules/*/db/migrate/*.rb`, run via ActiveRecord::MigrationContext or eval+migrate; commit.

## Task 6: :active_record provider
- [ ] Test: registering provider + Shaolin::Provider.start_all connects, creates event-store schema, registers `cqrs.event_store_backend` in Kernel; then :cqrs builds a durable store.
- [ ] Impl: `Shaolin::AR.register_provider!`; start { connect; schema.create!; Kernel.register("cqrs.event_store_backend", event_repository) }; commit.

## Task 7: README + green; merge.

## Definition of Done
- All green against PG; no file > ~150 lines; APIs verified; integrates with :cqrs (durable event store end-to-end).

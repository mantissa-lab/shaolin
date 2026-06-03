# shaolin-activerecord

ActiveRecord integration for [shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-activerecord-design.md):
the durable **event-store backend** consumed by shaolin-cqrs, plus the **read-model** base and
per-module migrations for the CQRS read side.

## Components

| Component | Purpose |
|---|---|
| `Shaolin::AR::Connection` | Standalone `establish_connection` + fiber/thread isolation level |
| `Shaolin::AR::EventStoreSchema` | `create!`/`drop!` the RubyEventStore tables (no Rails) |
| `Shaolin::AR.event_repository` | `PgLinearizedEventRepository` (advisory-lock ordering, YAML serializer) |
| `Shaolin::AR::ReadModel` | AR base with idempotent `project(id:) { |r| … }` upsert |
| `Shaolin::AR::Migrator` | runs `app/modules/*/db/migrate/*.rb` |
| `:active_record` provider | connects, ensures schema, registers `cqrs.event_store_backend` |

## Roles of ActiveRecord

1. **Event-store backend** — `event_store_events` + `event_store_events_in_streams`, injected into
   shaolin-cqrs's `RubyEventStore::Client` (register `:active_record` *before* `:cqrs`).
2. **Read models** — per-module projection tables; projections call `ReadModel.project(id:)`.

## Read model + projection

```ruby
class UserRecord < Shaolin::AR::ReadModel
  self.table_name = "users_read"
end

# in a projection, on each event:
UserRecord.project(id: event.data[:id]) do |r|
  r.email = event.data[:email]
end
```

`project` is an idempotent upsert keyed by id, so rebuilding a read model by replaying the event
stream is deterministic (set absolute state, don't increment).

## Serialization choice

Events use the **binary column + YAML serializer** (`PgLinearizedEventRepository`): robust
round-trip of symbol keys (`event.data[:email]`), and a globally linearized order under concurrent
writers via PostgreSQL advisory locks. (jsonb + JSON was rejected — it reads symbol keys back as
strings.)

See the [design spec](../../docs/superpowers/specs/2026-06-03-shaolin-activerecord-design.md).

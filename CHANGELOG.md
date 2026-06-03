# Changelog

All notable changes to shaolin. The framework is pre-1.0; gems share the `0.1.0` line and are not yet
published (consumed as path gems). For full usage see [`llms.txt`](llms.txt) and [`docs/`](docs/).

**For an agent already using shaolin:** this file is your "what changed" source. After pulling, run
`bundle update shaolin-*` in your app. The headline change is that the **transactional outbox is now
atomic by default** — re-read the Reliability section below and `docs/EVENTS.md`.

## [Unreleased]

### Reliability (changes guarantees — read first)

- **Transactional outbox is atomic by default.** A command's unit of work now runs in a single DB
  transaction: event append + synchronous projections + reactor outbox-enqueue commit or roll back
  together. No manual `ActiveRecord::Base.transaction` is needed anymore. A crash can no longer leave
  an event without its reactor job. (Enabled by the `:active_record` provider registering a
  `cqrs.transaction` runner that the aggregate repository wraps the unit of work in.)
- **Idempotent enqueue.** Unique `(reactor, event_id)` index + `INSERT ... ON CONFLICT DO NOTHING`, so
  re-publishing an event never duplicates a job (and never aborts the append transaction).
- **Optimistic-concurrency clashes map to HTTP 409**, not 500 (`RubyEventStore::WrongExpectedEventVersion`).
- **Schema creation is advisory-locked** (event store + jobs), safe for concurrent N-replica boots.

### Async / microservices

- **Reactors**: `shaolin g module <name> --reactor` scaffolds a `Shaolin::Jobs::Reactor` (`on(Event){…}`)
  + spec. Reactors run in `shaolin worker` via the outbox (at-least-once → must be idempotent).
- **`shaolin worker`** (retries + exponential backoff, dead-letter, `FOR UPDATE SKIP LOCKED`, graceful
  SIGTERM) and **`shaolin scheduler`** (cron via `Shaolin.schedule`, single leader via PG advisory
  lock; a failing task is isolated and never aborts the loop or the other tasks).
- **Broker transports** — both implement the same `Shaolin::Messaging::Publisher` port, so a reactor
  switches transport with zero code change:
  - **`shaolin-rabbitmq`** (bunny, pure Ruby): `Publisher` + `Consumer` (topic exchange, routing key =
    event_type).
  - **`shaolin-redis`** Streams: `StreamPublisher` + `StreamConsumer` (consumer groups, `XACK`,
    `XAUTOCLAIM` reclaim) + `PubSub` (fire-and-forget).
- **Worker fallback**: if an event was pruned from the store, the worker rebuilds it from the outbox
  row's YAML payload.

### Redis (`shaolin-redis`) — cache, store, broker

- **Cache** `Shaolin::Redis::Cache` implements the new `Shaolin::Cache` port (swap with the in-memory
  `Shaolin::Cache::Memory`): `fetch(key, ttl:){…}`, `read/write/delete/clear`, server-side TTL, JSON
  values with symbol keys.
- **Store** `Shaolin::Redis::Store` ("Redis as a database"): JSON `set/get`, native `increment`,
  `hset/hget/hgetall`, namespaced `keys`. For read models, sessions, counters, LLM state.
- `Shaolin::Redis.register_provider!(url:, namespace:)` registers
  `redis.pool` / `redis.cache` / `cache.store` / `redis.store` / `redis.publisher`.

### HTTP / operability

- **Error boundary**: any exception escaping a controller becomes the JSON contract
  `{ "error": { "code", "message" } }` (no stack-trace leak; generic message in production).
- **Probes**: `GET /healthz` (liveness), `GET /readyz` (readiness — runs `Shaolin::Health` checks; AR
  registers a DB ping, Redis a PING; 503 if any down), `GET /metrics` (Prometheus: `shaolin_up` +
  outbox queue depth by status).
- **Observability**: `x-request-id` on every response (propagated from an inbound header) + one
  structured JSON access-log line per request. Worker/scheduler emit structured JSON logs too
  (`reactor.done/retry/dead`, `schedule.fired/failed`). `SHAOLIN_LOG=off` silences logs.
- **Body cap**: `SHAOLIN_MAX_BODY_BYTES` (default 1 MiB) → 413 before buffering.
- **Custom middleware hook** for auth / rate limiting / CORS — plain Rack, plug in the ecosystem:
  ```ruby
  Shaolin::HTTP.register_provider!(middleware: [
    ->(app) { Rack::Cors.new(app) { |c| … } },     # rack-cors
    ->(app) { Rack::Attack.new(app) },              # rack-attack
    ->(app) { Rack::Auth::Basic.new(app) { |u, p| … } } # or warden / a jwt middleware
  ])
  ```
  Runs inside the error boundary + request logger, before the router; can short-circuit (401/429).
  **Devise is Rails-coupled and does NOT work standalone — use warden or jwt.**

### Operations

- **Migrations are a release step.** With `SHAOLIN_ENV=production`, boot does not auto-create schema or
  migrate. Run `shaolin migrate` (event store + jobs schema + read-model migrations, advisory-locked)
  per release; `shaolin rollback [STEPS]` to undo.
- **Queue ops**: `shaolin jobs stats | dead | retry <id>`.
- **DB pool**: `DB_POOL` (≥ worker `--threads`), `DB_CHECKOUT_TIMEOUT`, `DB_REAPING_FREQUENCY`. Falcon
  gets `:fiber` connection isolation automatically; the worker stays `:thread`.

### Multi-tenancy & event versioning

- `Shaolin::Tenant.with(id) { … }` / `Shaolin::Tenant.current` — a fiber/thread-scoped tenant context.
  The framework carries the value; you weave it into ids / stream prefixes / read-model columns.
- Event upcasting via `cqrs.event_mapper` (a RES `PipelineMapper` with `Transformation::Upcast`) —
  recipe in `docs/EVENTS.md`.

### Tooling & CI

- `shaolin describe --json` now lists each module's `reactors` (with subscribed events) and top-level
  `scheduled` tasks; `shaolin lint` covers reactor files.
- CI skeleton at `.github/workflows/ci.yml` (Postgres + Redis services). Test DB config reads `DB_*`
  env (local default `/tmp:5433`).

### Examples

- `examples/reactor` — event → transactional outbox → `worker` → reactor side effect (`verify.rb`).
- `examples/redis` — cache + store + Streams broker end-to-end (`verify.rb`).

## Gems

`shaolin-core`, `-cqrs`, `-activerecord`, `-dto`, `-http`, `-server`, `-cli`, `-messaging`, `-jobs`,
`-rabbitmq`, `-redis` (11). Optional transports (`-rabbitmq`, `-redis`) are commented in the generated
`Gemfile` — uncomment what you need.

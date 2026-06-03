# shaolin-jobs + RabbitMQ + microservices — Design & Plan

**Date:** 2026-06-03
**Status:** Approved (requested by a downstream agent building on shaolin) — autonomous build
**Goal:** Bring shaolin to NestJS-level: keep the modular monolith, add a reliable async/
microservices story — transactional outbox + async reactors + worker + scheduler + a RabbitMQ
transport + a microservice app shape.

## Verified foundation (probed 2026-06-03)

A RubyEventStore **sync subscriber's DB write participates in the same transaction as the event
append**: wrapping `client.publish` in `ActiveRecord::Base.transaction` and rolling back leaves
`event_store_events = 0` AND the subscriber's insert = 0; on commit both are present. → A
**transactional outbox** is achievable by registering a sync subscriber that INSERTs an outbox row;
it commits atomically with the event. (The command handler's unit-of-work must run in one AR
transaction — wrap `unit_of_work` in `ActiveRecord::Base.transaction`.)

## Phases (dependency order; each: TDD, files < ~150 lines, all suites + demoapp green, commit/merge)

### Phase 1 — `shaolin-jobs` gem: transactional outbox + async Reactor
- AR migration for `shaolin_jobs` (outbox): `id, reactor (string), event_id (uuid), event_type,
  payload (text/yaml), status (pending/done/failed/dead), attempts (int), run_at (timestamp),
  last_error (text), timestamps`. Goes through the framework migrator OR a `shaolin db` task.
- `Shaolin::Jobs::Reactor` base — DX mirrors Projection: `on(EventClass) { |event| ... }`. The
  block is the async side-effect handler (NOT run in the publish tx). Must be idempotent (doc it).
- `Shaolin::Jobs::Outbox` repo: `enqueue(reactor:, event:)`, `claim_batch(limit:)` using
  `SELECT ... FOR UPDATE SKIP LOCKED`, `mark_done/mark_failed(job, error, backoff)`.
- Provider (`:jobs`, after :active_record/:cqrs): auto-subscribe each module's `reactors.*` to the
  event store as **enqueue** subscribers — on a subscribed event, INSERT an outbox row (in the
  append tx). Wrap `AggregateRepository#unit_of_work` in `ActiveRecord::Base.transaction` so enqueue
  is atomic with the event. (In-memory store / no AR backend: reactors run sync — documented.)
- Reconcile naming: keep `Shaolin::Messaging::Reactor` as the domain→integration *mapper* used
  INSIDE a jobs Reactor's side-effect, OR deprecate it. Async base lives here.

### Phase 2 — `shaolin worker` runtime
- A process that polls the outbox (`FOR UPDATE SKIP LOCKED`), loads the event from the event store
  by `event_id`, runs the matching Reactor's handler, marks `done`; on raise marks `failed` and
  schedules a retry.
- **Retries with exponential backoff**: configurable `max_attempts` + schedule (e.g. 1s,10s,1m,
  10m,1h). Exhausted → `dead` (dead-letter, kept in table for inspection/manual replay).
- Concurrency: N threads/workers. Graceful shutdown (SIGTERM, reuse shaolin-server lifecycle).
- Same AR/Postgres backend as the event store. CLI: `shaolin worker`.

### Phase 3 — `shaolin scheduler`
- Periodic tasks by cron-ish spec: `Shaolin.schedule "retry_failed", every: "1m"` (or a task class)
  declared in a module; the scheduler enqueues them into the same jobs/outbox mechanism.
- **Single leader** across replicas via a Postgres advisory lock (`pg_try_advisory_lock`), so a
  task fires once. CLI: `shaolin scheduler`.

### Phase 4 — `shaolin-rabbitmq` gem (transport adapter; bunny is pure-Ruby, no system lib)
- `Shaolin::RabbitMQ::Publisher` implements the `Shaolin::Messaging::Publisher` port via `bunny`
  (publish the IntegrationEvent envelope to an exchange/topic = `event_type`).
- Consumer worker: subscribe a queue → parse envelope → validate via DTO → dispatch a Command on
  the command bus (same write path as HTTP/inbound). CLI: `shaolin rabbitmq consume` (or fold into
  worker).
- Reliability: reactors publish to RabbitMQ **through the outbox** (the worker does the actual
  `bunny` publish), so delivery is at-least-once even across crashes.
- Unit-test with a mock/stub bunny channel (no broker). Live two-service demo when a broker is up
  (`docker run rabbitmq:3` or `apt install rabbitmq-server`).

### Phase 5 — microservice app shape
- `shaolin new <name> --service` (or doc): a service that is broker-first — runs `shaolin worker`
  (+ optional HTTP), consumes integration events → commands, publishes its own. Deployed as a GKE
  worker (already have the manifest shape).
- Demo: two generated services exchanging an event reliably (service A: command → event → outbox →
  worker → RabbitMQ publish; service B: consume → command → its own event). Proves
  monolith ↔ microservices is the documented switch.

## Agent-tool integration (required)
- `shaolin g module` (+ optional flag, e.g. `--reactor`): scaffold a Reactor + its spec in the module.
- `shaolin describe --json`: include each module's `reactors` and `scheduled` tasks.
- `shaolin lint`: Reactors obey the same module-isolation rules (already covered — they're `.rb`
  files in the module folder; the linter scans them).
- Update `llms.txt` + docs with a new Reactor/worker/scheduler section; design spec lives here.

## Acceptance criteria (E2E, like examples/demo)
1. Module with a Reactor: on event publish a job appears in the outbox **in the same transaction**;
   if the transaction rolls back, NO job appears. (TDD + a verify script.)
2. `shaolin worker` claims a pending job, runs the Reactor, marks it `done`.
3. A failing Reactor → job goes to retry with backoff; after `max_attempts` → `dead` (stays in table).
4. Two worker replicas never run the same job twice (`FOR UPDATE SKIP LOCKED`).
5. `shaolin scheduler` enqueues a task by cron; with two replicas only one fires (advisory lock).
6. All gem specs green; `examples/demo` still green; add a **mini Reactor demo** to `examples/`
   with a `verify` script (publish event → see job → run worker → see side effect / done).

## Conventions (hard)
- TDD; small files; cross-gem only via kernel/providers + documented keys (`cqrs.*`, `jobs.*`).
- Don't break sync Projections (read models stay synchronous, in-tx). Reactor = separate async path.
- Migrations via the framework migrator. At-least-once → idempotent reactors (documented).
- After each phase: all gem suites + demoapp e2e green (clean DB with `-d postgres`), commit/merge,
  update memory + demoapp/BACKLOG.md, reschedule.

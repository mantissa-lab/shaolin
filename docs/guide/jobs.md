# Jobs: outbox, reactors, worker, scheduler

`shaolin-jobs` (`require "shaolin/jobs"`, gem version `0.1.0`) provides reliable
async side-effects via a **transactional outbox**. A `Reactor` enqueues an outbox
row in the **same DB transaction** as the event it reacts to; a separate `shaolin
worker` process later runs the reactor. Delivery is **at-least-once** → reactors
**must be idempotent**.

The headline reliability property: an event append, its synchronous projections,
and the async-reactor enqueue all commit in **one** transaction. If the append
rolls back, no job is left behind.

```ruby
require "shaolin/jobs"
Shaolin::Jobs.register_provider!   # after :active_record and :cqrs

Shaolin::Jobs::VERSION   # => "0.1.0"  — the gem's version string constant
```

Everything lives under `Shaolin::Jobs`. The provider registers `jobs.outbox` in
the kernel, creates the tables, and wires reactors + async projections to the
event store as enqueue callbacks.

---

## Big picture

| Piece | Class | Role |
|---|---|---|
| Reactor | `Shaolin::Jobs::Reactor` | Declares `on(...)` handlers; the side effect that runs later |
| Outbox | `Shaolin::Jobs::Outbox` | Repository: `enqueue`, `claim`, mark done/failed, stats, dead/retry |
| Outbox row | `Shaolin::Jobs::OutboxJob` | AR model on `shaolin_jobs` |
| Worker | `Shaolin::Jobs::Worker` | Drains the outbox (`shaolin worker`) |
| Scheduler | `Shaolin::Jobs::Scheduler` | Periodic tasks, single leader (`shaolin scheduler`) |
| Schedule DSL | `Shaolin.schedule` / `Shaolin::Jobs::Schedules` | Register periodic tasks |
| Schedule row | `Shaolin::Jobs::ScheduleRun` | AR model on `shaolin_schedules` |
| Schema | `Shaolin::Jobs::Schema` | Creates the two tables (idempotent) |
| Provider | `Shaolin::Jobs.register_provider!` | The `:jobs` provider |

Lifecycle of one job: event published → enqueue callback inserts a `pending`
outbox row in the append tx → worker `claim`s it (`FOR UPDATE SKIP LOCKED`) →
loads the event → `Reactor.new.call(event)` → `done`, or `failed` (retry with
backoff), or `dead` (retries exhausted).

---

## Reactor — `Shaolin::Jobs::Reactor`

Base class for async reactors (send email, publish to a broker, call an external
API). DX mirrors `Shaolin::CQRS::Projection` — declare handlers with `on(...)` —
but the handler runs **later** in the worker, not in the event's transaction.
Includes `Shaolin::Imports`, so `import("other.key")` works inside handler blocks
(blocks run via `instance_exec`).

| Method | Signature | Purpose |
|---|---|---|
| `.on` | `on(event_or_topic, &block)` | Subscribe to an event class **or** a topic string |
| `.handlers` | `handlers → Hash{Class=>block}` | Registered class handlers |
| `.topic_handlers` | `topic_handlers → Hash{String=>block}` | Registered topic handlers (pre-resolution) |
| `.subscribed_events` | `subscribed_events → [Class]` | `handlers.keys` |
| `.subscribed_topics` | `subscribed_topics → [String]` | `topic_handlers.keys` |
| `.bind_topic` | `bind_topic(topic, event_class)` | Provider hook: bind a topic's block under the resolved class |
| `#call` | `call(event)` | Run the side effect — dispatches `handlers[event.class]` |

Two subscription forms:

```ruby
module Things
  module Reactors
    class WelcomeMailer < Shaolin::Jobs::Reactor
      # 1) OWN module's event — by class
      on(Things::Events::UserRegistered) do |event|
        import("mail.sender").deliver(to: event.data[:email]) # cross-module, lint-checked
      end

      # 2) ANOTHER module's event — by topic string (no cross-module constant)
      on("billing.invoice_paid") { |event| MyMetrics.bump(event.data[:amount]) }
    end
  end
end
```

- **Topic form gotcha:** the topic must be declared in this module's manifest as
  `imports events: ["billing.invoice_paid"]`. At wire time the `:jobs` provider
  resolves the topic to its event class (`Shaolin::Topic.event_class_name`,
  e.g. `"billing.invoice_paid" → Billing::Events::InvoicePaid`) and calls
  `bind_topic`, which copies the block into `handlers[event_class]`. After that,
  `call(event)` dispatch is identical for both forms.
- **Resolution failure is loud:** if the resolved class isn't defined, the
  provider raises `Shaolin::Error` ("reactor subscribes to topic … but its event
  class … is not defined").
- **`call` is a no-op** if no handler matches `event.class` (block is `nil`).
- Reactors are discovered by the provider via the module container key prefix
  `reactors.` (place them in `app/modules/<mod>/reactors/`).

---

## Outbox — `Shaolin::Jobs::Outbox`

The transactional outbox repository. Registered as `jobs.outbox` in the kernel.

**Constants:**

| Constant | Value | Meaning |
|---|---|---|
| `DEFAULT_BACKOFF` | `[1, 10, 60, 600, 3600]` (seconds) | Retry delays; size also defaults `max_attempts` to 5 |
| `CHANNEL` | `"shaolin_jobs"` | Postgres `LISTEN`/`NOTIFY` channel that wakes idle workers |
| `CLAIMABLE` | `%w[pending failed]` | Statuses that are due/claimable |

| Method | Signature | Purpose |
|---|---|---|
| `#enqueue` | `enqueue(reactor:, event:, run_at: Time.now)` | Insert a pending row (idempotent) + best-effort `NOTIFY` |
| `#claim` | `claim(limit:, now: Time.now)` | Lock & return up to `limit` due jobs (`FOR UPDATE SKIP LOCKED`) |
| `#mark_done` | `mark_done(job)` | Set status `done`, clear `last_error` |
| `#mark_failed` | `mark_failed(job, error:, backoff: DEFAULT_BACKOFF, max_attempts: DEFAULT_BACKOFF.size, now: Time.now)` | Retry with backoff, or dead-letter |
| `#stats` | `stats → Hash{status=>count}` | Counts by status |
| `#oldest_pending_age` | `oldest_pending_age(now: Time.now) → Float` | Seconds since the oldest due job was due (worker-lag signal) |
| `#dead` | `dead(limit: 50) → [OutboxJob]` | Dead-lettered jobs, newest first |
| `#retry!` | `retry!(id, now: Time.now) → Integer` | Re-queue a dead job (returns rows updated) |

```ruby
outbox = Shaolin::Kernel["jobs.outbox"]   # or Shaolin::Jobs::Outbox.new

outbox.stats               # => {"pending"=>3, "failed"=>1, "done"=>120, "dead"=>0}
outbox.oldest_pending_age  # => 12.4  (0.0 when nothing is due)
outbox.dead.map(&:reactor) # => ["Billing::Reactors::ChargeCard"]
outbox.retry!(42)          # => 1   (0 if id 42 isn't dead)
```

**`enqueue` details / gotchas:**

- Uses `insert_all(..., unique_by: %i[reactor event_id])` → `ON CONFLICT DO
  NOTHING` on the `(reactor, event_id)` unique index. Re-publishing an event
  never enqueues a duplicate, and — because it runs as a sync subscriber inside
  the event-append transaction — a conflict can't abort that transaction (unlike
  a raising `create!`).
- The row stores `payload: YAML.dump(event.data)` so the job is self-contained.
- `NOTIFY shaolin_jobs` is **best-effort**: any failure is swallowed so it can
  never break the append. The NOTIFY is delivered on commit (we're inside the
  append tx).
- `run_at:` lets you delay a job (default = now).

**`claim` details / gotchas:**

- **MUST be called inside a transaction.** The row locks are held until that
  transaction ends — other workers `SKIP LOCKED` them, and a crash mid-process
  rolls the job back to its prior state (re-claimable).
- Due = status in `CLAIMABLE` (`pending` or `failed`) **and** `run_at <= now`,
  ordered by `run_at`.

**`mark_failed` semantics:** increments `attempts`; if `attempts >= max_attempts`
→ `dead` (kept in the table for inspection); otherwise → `failed` with
`run_at = now + backoff[min(attempts-1, last)]`. The backoff array is clamped, so
attempts beyond its length reuse the last delay.

---

## OutboxJob — `Shaolin::Jobs::OutboxJob`

`ActiveRecord::Base` on table `shaolin_jobs`. One row = a pending reactor
invocation.

| Column | Type | Notes |
|---|---|---|
| `reactor` | string, not null | Reactor class name (also async-projection class name) |
| `event_id` | string, not null | RubyEventStore event id |
| `event_type` | string, not null | Event class name (used for payload reconstruction) |
| `payload` | text | `YAML.dump(event.data)` |
| `status` | string, not null, default `pending` | `pending` \| `done` \| `failed` (will retry) \| `dead` (exhausted) |
| `attempts` | integer, not null, default `0` | Incremented on each failure |
| `run_at` | datetime, not null | Due time (drives ordering, backoff, delay) |
| `last_error` | text | Last error message (nil once done) |
| `created_at`/`updated_at` | datetime | timestamps |

Indexes: `(status, run_at)` (claim scan) and a **unique** `(reactor, event_id)`
(idempotent enqueue).

---

## Worker — `Shaolin::Jobs::Worker`

Drains the outbox: claims due jobs (`FOR UPDATE SKIP LOCKED`), loads the event,
runs the reactor, marks done/failed. Failures retry with backoff; exhausted ones
are dead-lettered. Constructed from the CLI by `shaolin worker`.

```ruby
def initialize(event_store:, outbox: Outbox.new, batch: 20, tx_per_job: false,
               backoff: Outbox::DEFAULT_BACKOFF, max_attempts: Outbox::DEFAULT_BACKOFF.size,
               listen: true, prefer_payload: false)
```

| kwarg | Default | Meaning |
|---|---|---|
| `event_store:` | (required) | Source for `read.event(event_id)` — pass `Shaolin::Kernel["cqrs.event_store"]` |
| `outbox:` | `Outbox.new` | Outbox repository |
| `batch:` | `20` | Max jobs drained per `run_once` (CLI: `WORKER_BATCH`) |
| `tx_per_job:` | `false` | One tx per job vs. one tx per batch (CLI: `WORKER_TX_PER_JOB`) |
| `backoff:` | `[1,10,60,600,3600]` | Retry delays passed to `mark_failed` |
| `max_attempts:` | `5` (`DEFAULT_BACKOFF.size`) | Attempts before dead-letter |
| `listen:` | `true` | Wait on Postgres `NOTIFY` when idle (else plain poll sleep) |
| `prefer_payload:` | `false` | Rebuild the event from the outbox row's YAML instead of reloading from the store |

| Method | Signature | Purpose |
|---|---|---|
| `#run_once` | `run_once(now: Time.now) → Integer` | Drain up to `batch` due jobs; returns count processed |
| `#run` | `run(poll_interval: 0.5, threads: 1)` | Long-running loop on a fixed thread pool, graceful SIGTERM/INT |
| `#stop!` | `stop!` | Flip the stop flag (ends `run`) |

```ruby
worker = Shaolin::Jobs::Worker.new(event_store: Shaolin::Kernel["cqrs.event_store"])

worker.run_once                # process a batch now → e.g. 3
worker.run(poll_interval: 0.5, threads: 2)  # blocks until SIGTERM/INT or stop!
```

**Transaction modes (the trade-off matters for IO-bound reactors):**

- **default — batch in ONE transaction** (`drain_batch`): claims `batch` jobs and
  processes them all in a single tx. Row locks + the tx are held for the whole
  batch. Fewer round-trips; fine for fast CPU-bound reactors.
- **`tx_per_job: true`** (`drain_per_job`): each job is claimed + processed +
  committed in its own short tx, looping until `batch` are done or the queue is
  empty. A slow outbound call (HTTP to an external API) holds a lock for just that
  one job and commits independently. Use this for **IO-bound** reactors; tune
  `batch` to bound how many jobs one `run_once` drains.

**Idle wake-up (`listen`):** when a drain finds nothing, the worker `LISTEN`s on
`Outbox::CHANNEL` and blocks up to `poll_interval` for a `NOTIFY` (fired by
`enqueue`), so new jobs are picked up immediately instead of after the poll
interval. NOTIFY is an **optimization, not a correctness dependency** — any
LISTEN/NOTIFY hiccup degrades to a plain `sleep(poll_interval)`, and polling is
the correctness floor that catches any missed NOTIFY next tick. With
`listen: false` the worker just polls.

**Event loading (`load_event`):** normally reads the canonical event from the
store by `event_id`. Two fallbacks to the row's own YAML payload:

1. `prefer_payload: true` and the row has a payload → skip the store round-trip.
2. The store raises `RubyEventStore::EventNotFound` (stream pruned/archived) → the
   job rebuilds the event from its payload instead of getting stuck.

Payload rebuild uses `YAML.safe_load(..., permitted_classes: [Symbol, Time, Date],
aliases: true)` and `Object.const_get(job.event_type).new(event_id:, data:)`. The
store is canonical (e.g. after event upcasting), which is why `prefer_payload` is
off by default.

**Resilience:** `safe_run_once` swallows transient DB/lock errors in a poll
(logs `worker.run_failed`) so the loop survives. `process` reconstructs the
event, instantiates the reactor via `Object.const_get(job.reactor).new`, runs it,
and on error calls `mark_failed`, logging `reactor.retry` (warn) or `reactor.dead`
(error); success logs `reactor.done` (info).

**CLI:** `shaolin worker` reads ENV:

| ENV var | Default | Maps to |
|---|---|---|
| `WORKER_CONCURRENCY` | `1` | `run(threads:)` |
| `WORKER_BATCH` | `20` | `batch:` |
| `WORKER_TX_PER_JOB` | unset | `tx_per_job:` (`1`/`true` enables) |

It warns if `WORKER_CONCURRENCY` exceeds the AR connection pool size (set
`DB_POOL >= threads` to avoid connection timeouts).

---

## Scheduler — `Shaolin::Jobs::Scheduler`

Runs periodic tasks. A single **leader** across replicas via a Postgres advisory
lock, so each due task fires once per tick even with N schedulers. Constructed by
`shaolin scheduler`.

| Constant | Value | Meaning |
|---|---|---|
| `ADVISORY_KEY` | `7_283_001` | Stable key for the scheduler leader lock |

```ruby
def initialize(schedules: Schedules)
```

| Method | Signature | Purpose |
|---|---|---|
| `#tick` | `tick(now: Time.now) → [String]` | Become leader, run due schedules, persist `last_run`; returns names fired (`[]` if not leader / nothing due) |
| `#run` | `run(interval: 1.0)` | Loop on a `Concurrent::TimerTask`, graceful SIGTERM/INT |
| `#stop!` | `stop!` | Stop the run loop |

```ruby
Shaolin::Jobs::Scheduler.new.run(interval: 1.0)   # blocks; or .tick for one pass
```

**`tick`:** `pg_try_advisory_lock(ADVISORY_KEY)` — if not acquired, returns `[]`
immediately (another replica is leader). While leader, runs each due schedule and
releases the lock in an `ensure`. A schedule is **due** if it has never run or
`now - last_run_at >= interval`.

**Failure isolation:** for each due entry the scheduler records `last_run_at` (via
`ScheduleRun.find_or_initialize_by`) **before** calling the block, so a failing
task still respects its interval (no per-tick hammering) and one bad task can't
abort the loop or block the others. Successful runs log `schedule.fired`; failures
log `schedule.failed` and are swallowed.

**`run`:** a `Concurrent::TimerTask` (`run_now: true`) ticks every `interval`
seconds in its own thread; a DB blip / lock error in one tick is caught (logs
`scheduler.tick_failed`), not fatal. The caller parks on a `Concurrent::Event`
until SIGTERM/INT, then shuts the task down.

**CLI:** `shaolin scheduler` calls `Scheduler.new.run` (interval `1.0`).

---

## Schedule DSL — `Shaolin.schedule` / `Shaolin::Jobs::Schedules`

Module-level DSL to register periodic tasks (put these in your boot/config so they
load at startup).

```ruby
def Shaolin.schedule(name, every:, &block)
```

```ruby
Shaolin.schedule("retry_dead", every: "1m") do
  Shaolin::Kernel["jobs.outbox"].dead(limit: 100).each { |j| outbox.retry!(j.id) }
end
```

`every:` accepts `\A(\d+)([smhd])\z` — e.g. `"10s"`, `"1m"`, `"1h"`, `"1d"`
(seconds / minutes / hours / days). A bad format raises `ArgumentError`.

**`Shaolin::Jobs::Schedules`** (the registry):

| Member | Signature | Purpose |
|---|---|---|
| `Entry` | `Struct.new(:name, :interval, :block)` | One registered task |
| `UNITS` | `{"s"=>1,"m"=>60,"h"=>3600,"d"=>86_400}` | Interval unit table |
| `.register` | `register(name, interval_seconds, &block)` | Store an entry (keyed by name string) |
| `.all` | `all → [Entry]` | All entries |
| `.reset!` | `reset!` | Clear the registry (tests) |
| `.parse_interval` | `parse_interval(str) → Integer` | `"1h" → 3600`; raises `ArgumentError` on bad input |

`Shaolin.schedule` is sugar over `Schedules.register(name,
Schedules.parse_interval(every), &block)`. Names are stored as strings, so
re-registering the same name overwrites.

---

## ScheduleRun — `Shaolin::Jobs::ScheduleRun`

`ActiveRecord::Base` on table `shaolin_schedules`. Persisted last-run time per
schedule, so cadence survives restarts and is shared across replicas.

| Column | Type | Notes |
|---|---|---|
| `name` | string, not null | Unique index; matches `Entry#name` |
| `last_run_at` | datetime | nil = never run (always due) |

---

## Schema — `Shaolin::Jobs::Schema`

Creates the jobs tables (idempotent). Called by the `:jobs` provider at boot.

| Member | Signature | Purpose |
|---|---|---|
| `SCHEMA_LOCK_KEY` | `7_283_011` | Advisory lock guarding creation |
| `.create!` | `create!` | Create both tables under the advisory lock |
| `.create_outbox` | `create_outbox(conn)` | Create `shaolin_jobs` + indexes |
| `.create_schedules` | `create_schedules(conn)` | Create `shaolin_schedules` + unique name index |

```ruby
ActiveRecord::Base.establish_connection(config)
Shaolin::Jobs::Schema.create!   # safe to call repeatedly
```

`create!` holds `pg_advisory_lock(SCHEMA_LOCK_KEY)` so concurrent replica boots
can't race the `table_exists?`-then-`create` check. `create_outbox` also *upgrades*
a pre-existing table that lacks the `(status, run_at)` or unique `(reactor,
event_id)` indexes. In production you typically rely on `shaolin migrate` rather
than auto-schema; the provider calls `create!` at boot regardless (it's a no-op
when the tables exist).

---

## DriveReactor (in `shaolin-harness`)

Not part of `shaolin-jobs`, but the canonical reactor consumer worth knowing:
`Shaolin::Harness::DriveReactor` is a durable, crash-resumable driver that the
worker runs on each `GateEntered` (via the outbox). Each advance appends the next
`GateEntered`, which enqueues the next `DriveReactor` job — the harness loop
self-perpetuates across worker ticks. It is **idempotent under at-least-once
delivery**: it only advances when the event's gate is still the run's current gate
(stale redeliveries skipped) and never touches a terminal run. The harness wires
it manually with `outbox.enqueue(reactor: "Shaolin::Harness::DriveReactor",
event: event)` rather than through the `on(...)` DSL — illustrating that any class
with `#call(event)` resolvable by name from the `reactor` column works as a
worker target.

---

## Async projections

A `Shaolin::CQRS::Projection` marked `async` (`self.async = true` via the `async`
macro; queried with `async?`) is **not** run in the append transaction. Instead
it's driven through the outbox exactly like a reactor: the `:jobs` provider
subscribes an enqueue callback to the projection's `subscribed_events`, and the
worker runs `projection.call(event)`. The `:cqrs` provider skips async projections
from its **sync** subscription, so each runs exactly once — asynchronously,
eventually consistent, with idempotent upserts making at-least-once safe.

```ruby
module Gizmos
  module Projections
    class GizmoProjection < Shaolin::CQRS::Projection
      async                                   # off the append tx, worker-driven
      on(GizmoMade) { |event| upsert(event.data[:id]) }   # must be idempotent
    end
  end
end
```

On publish, no synchronous run happens; a `pending` outbox row is enqueued
(`reactor` = the projection class name). After `Worker#run_once`, the projection
has run and the job is `done`. Discovery is by the container key prefix
`projections.` (vs. `reactors.` for reactors).

---

## The `:jobs` provider

`Shaolin::Jobs.register_provider!` registers the `:jobs` provider. **Register it
AFTER `:active_record`** (needs the connection + schema) **and `:cqrs`** (needs the
shared event store).

| Method | Signature | Purpose |
|---|---|---|
| `.register_provider!` | `register_provider!` | Register the `:jobs` provider |
| `.wire_reactors` | `wire_reactors(event_store, outbox)` | Subscribe reactor enqueue callbacks |
| `.wire_async_projections` | `wire_async_projections(event_store, outbox)` | Subscribe async-projection enqueue callbacks |
| `.bind_topics` | `bind_topics(klass)` | Resolve a reactor's topic subscriptions to classes |
| `.resolve_event` | `resolve_event(topic) → Class` | Topic → event class (raises `Shaolin::Error` if undefined) |

On `start` the provider:

1. `Schema.create!` — ensure `shaolin_jobs` + `shaolin_schedules`.
2. `Shaolin::Kernel.register("jobs.outbox", Outbox.new)`.
3. `wire_reactors(event_store, outbox)` — for each container key matching
   `\Areactors\.`: call `bind_topics` (resolve topic strings to classes), then
   `event_store.subscribe(->(event){ outbox.enqueue(reactor: klass.name, event:) },
   to: klass.subscribed_events)`. Reactors with no subscribed events are skipped.
4. `wire_async_projections(event_store, outbox)` — same for container keys matching
   `\Aprojections\.` where the class `async?`.

```ruby
# config/boot.rb (order matters)
Shaolin::AR.register_provider!(config: db_config)
Shaolin::CQRS.register_provider!
Shaolin::Jobs.register_provider!
Shaolin::App.new(root: ROOT).boot!

outbox = Shaolin::Kernel["jobs.outbox"]   # available after boot
```

The enqueue callbacks run as **synchronous** event-store subscribers, which is
exactly why a job commits atomically with the event append (a rolled-back append
leaves no job — verified in the cross-module reactor spec).

---

## Structured logging — `Shaolin::Jobs::Log`

A thin shim onto the unified `Shaolin::Log`, so the worker/scheduler share one
structured pipeline + sinks with the rest of the framework.

| Method | Signature |
|---|---|
| `.emit` | `emit(level, msg, **fields)` → `Shaolin::Log.emit(level.to_sym, msg, **fields)` |

Emitted events: `worker.run_failed`, `reactor.done`, `reactor.retry`,
`reactor.dead`, `schedule.fired`, `schedule.failed`, `scheduler.tick_failed`.

---

## Operating the outbox (`shaolin jobs`)

```
shaolin jobs [stats]      # counts: pending / failed / done / dead
shaolin jobs dead         # list dead-lettered jobs (id, reactor, event_type, last_error)
shaolin jobs retry ID     # re-queue dead job ID (pending, attempts reset to 0)
```

Backed by `Outbox#stats`, `Outbox#dead`, and `Outbox#retry!`. `oldest_pending_age`
is the worker-lag metric to alert on.

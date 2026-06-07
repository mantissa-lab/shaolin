# Production & reliability under load

> Grounded in the code under `gems/shaolin-http`, `gems/shaolin-server`,
> `gems/shaolin-activerecord`, and `gems/shaolin-core`. Every signature below is the
> real one; defaults and ENV keys are exact.

shaolin defaults to **Falcon** (async, fiber-per-request). A fiber is nearly free, so
the server will happily accept thousands of concurrent requests — but each request that
touches the DB needs a connection from a **fixed pool** (`DB_POOL`, default 5). That
mismatch is the **load cliff**.

---

## 1. The load cliff

```
unbounded fibers  ───────────►  fixed DB pool (DB_POOL)
   accept everything               only N can run at once
```

Under a burst, Falcon accepts every connection and spawns a fiber per request. The first
`DB_POOL` fibers grab connections; the rest **block in `connection_pool.with_connection`
up to `checkout_timeout` (5s)**, then raise. Symptoms: latency collapses, every request
waits ~5s and then errors, throughput goes to zero while CPU looks idle. You don't fall
off gracefully — you fall off a cliff.

The fix is **four walls** in front of the pool, each opt-in, each returning fast instead
of piling work onto a saturated resource:

| Wall | Component | Protects against | Response |
|---|---|---|---|
| Admission control | `Shaolin::HTTP::Concurrency` | oversubscribing the DB pool | `503 overloaded` |
| Request timeout | `Shaolin::Server::Timeout` | a hung handler holding a fiber+connection forever | `503 timeout` |
| Rate limit | `Shaolin::HTTP::RateLimit` | a single client/IP monopolizing capacity | `429 rate_limited` |
| Circuit breaker | `Shaolin::CircuitBreaker` | a dependency brownout piling up doomed calls | raises `OpenError` |

---

## 2. Admission control — `Shaolin::HTTP::Concurrency`

Rack middleware that **bounds in-flight requests**. Past the cap it **load-sheds**:
returns `503` immediately rather than queueing behind a saturated pool. It also
registers itself in the kernel as `"http.concurrency"` so `/metrics` can read the gauge.

```ruby
Shaolin::HTTP::Concurrency.new(app, max:)   # max: Integer, required
#=> attr_reader :max
#   #in_flight  → Integer  (current acquired permits)
#   #call(env)  → 503 OVERLOADED once `max` permits are held, else passes through
```

Backed by a `Concurrent::Semaphore(max)` and a `Concurrent::AtomicFixnum` gauge. The
`503` body is `Shaolin::HTTP::Concurrency::OVERLOADED` (frozen):
`[503, {"content-type"=>"application/json","retry-after"=>"1"}, [%({"error":{"code":"overloaded",…})])]`.

```ruby
mw = Shaolin::HTTP::Concurrency.new(->(_env){ sleep; [200,{},["ok"]] }, max: 1)
mw.in_flight                  # => 0
# first request takes the only permit; a second concurrent one:
status, _h, body = mw.call({})
status                        # => 503
JSON.parse(body.first).dig("error","code")   # => "overloaded"
```

**Wiring** — do not `new` it yourself; it's installed by the `:http` provider when a cap
is set. The cap comes from `max_concurrency:` or the `SHAOLIN_WEB_CONCURRENCY` env var:

```ruby
Shaolin::HTTP.register_provider!(max_concurrency: 5)   # explicit
# or leave it nil and set ENV["SHAOLIN_WEB_CONCURRENCY"] = "5"
```

In `provider.rb`: `cap = max_concurrency || (ENV["SHAOLIN_WEB_CONCURRENCY"] && Integer(...))`.
The router wraps the app `Concurrency.new(app, max: cap) if cap` — **off by default**
(`cap` is `nil` → no wall, unbounded).

> **Gotcha:** load-shedding is *not* queueing. A shed request gets `503` right away with
> `Retry-After: 1`; it is the client's (or gateway's) job to retry. Set `max ≈ DB_POOL`.

---

## 3. Request timeout — `Shaolin::Server::Timeout`

Per-request **deadline** for the Falcon adapter. A slow/hung handler otherwise holds its
fiber **and** its checked-out DB connection forever, starving the pool. Uses
`Async::Task#with_timeout` — **cooperative** (interrupts only at yield points, so it's
safe, unlike Ruby's `Timeout`). On expiry it frees the fiber/connection and returns
`503`. **No-op when there is no current Async task** (so it's inert under Puma).

```ruby
Shaolin::Server::Timeout.new(app, seconds)   # seconds: Float|nil (positional)
#   #call(env) → app result, or 503 EXPIRED on Async::TimeoutError
```

`EXPIRED` (frozen): `[503, {"content-type"=>"application/json","retry-after"=>"1"}, [%({"error":{"code":"timeout",…})])]`.

```ruby
Async do
  slow = ->(_e){ sleep 5; [200,{},["late"]] }
  Shaolin::Server::Timeout.new(slow, 0.05).call({})   # => [503, …, ["…timeout…"]]
end
# Outside a reactor (Puma): inert, passes through
Shaolin::Server::Timeout.new(->(_e){[200,{},["ok"]]}, 0.001).call({})  # => [200,{},["ok"]]
```

**Wiring** — configured by ENV, installed by the Falcon adapter:

```ruby
# ENV["SHAOLIN_REQUEST_TIMEOUT"] = "10"   # seconds; nil/unset = off
# Server::Config reads it: @request_timeout = rt && Float(rt)
# Falcon#start: rack_app = Timeout.new(rack_app, config.request_timeout) if config.request_timeout
```

> **Gotcha:** cooperative timeout only fires at an `await`/yield point (DB I/O, HTTP,
> `Async`-aware `sleep`). A pure CPU spin loop will **not** be interrupted. On **Puma**
> this middleware is inert — use `Rack::Timeout` or Puma's own worker timeouts there.

---

## 4. Rate limit — `Shaolin::HTTP::RateLimit`

Fixed-window rate limiter, backed by any `Shaolin::Store` (Redis in prod,
`Shaolin::Store::Memory` in tests). The window key rotates by time bucket; the
`increment(ttl:)` call expires old buckets.

```ruby
Shaolin::HTTP::RateLimit.new(
  app,
  store:,                # any Shaolin::Store (responds to #increment(key, by:, ttl:))
  limit:,                # Integer, max requests per window per key
  window: 60,            # Integer seconds
  key: ->(env) { env["HTTP_X_FORWARDED_FOR"]&.split(",")&.first&.strip ||
                 env["REMOTE_ADDR"] || "anon" }   # default: client IP
)
```

- Bucket = `"ratelimit:#{key}:#{Time.now.to_i / window}"`; `store.increment(bucket, ttl: window*2)`.
- Over `limit` → `429` with `Retry-After: <window>` and body `{"error":{"code":"rate_limited",…}}`.
- Under: passes through and **adds headers** `x-ratelimit-limit` and `x-ratelimit-remaining`.

```ruby
store = Shaolin::Kernel["redis.store"]
Shaolin::HTTP.register_provider!(middleware: [
  ->(app) { Shaolin::HTTP::RateLimit.new(app, store: store, limit: 100, window: 60) }
])

# custom key (per-tenant instead of per-IP):
->(app) { Shaolin::HTTP::RateLimit.new(app, store: store, limit: 1000, window: 60,
                                       key: ->(env){ env["tenant"] }) }
```

> **Gotchas:** *fixed* window (not sliding) — a client can do up to `2*limit` across a
> bucket boundary. Default key trusts `X-Forwarded-For`; only safe behind a trusted
> proxy that sets it. `Store::Memory#increment` ignores `ttl:` (test-only); use Redis in
> prod so buckets actually expire. Middleware runs **inside** the error boundary + request
> logger, before the router, and can short-circuit.

---

## 5. Circuit breaker — `Shaolin::CircuitBreaker`

Thread-safe breaker (stdlib only) for **outbound** calls (RabbitMQ / Redis / HTTP). After
`threshold` consecutive failures it **opens** and fast-fails for `reset_timeout` seconds,
then **half-opens** to trial one call — success **closes** it, a failure **re-opens** it.

```ruby
Shaolin::CircuitBreaker.new(
  threshold: 5,          # consecutive failures before opening
  reset_timeout: 30,     # seconds open before half-open trial
  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
)
#   #call { ... } → block result; raises CircuitBreaker::OpenError while open;
#                   re-raises the block's error on failure
#   #state        → :closed | :open | :half_open
```

`Shaolin::CircuitBreaker::OpenError < Shaolin::Error` is raised **instead of** calling the
block while open (a brownout doesn't pile up doomed calls).

```ruby
breaker = Shaolin::CircuitBreaker.new(threshold: 2, reset_timeout: 30)
2.times { breaker.call { raise "boom" } rescue nil }
breaker.state                                   # => :open
breaker.call { publisher.publish(ie) }          # raises Shaolin::CircuitBreaker::OpenError
# after reset_timeout: state => :half_open; one trial decides closed/open
```

> **Gotchas:** only `StandardError` (and subclasses) counts as a failure; other exceptions
> propagate without tripping. `threshold` counts *consecutive* failures — any success while
> closed resets the count to 0. State transitions are lazy: `:open → :half_open` is computed
> on read once `reset_timeout` has elapsed.

---

## 6. Sizing the pool and the walls — `Shaolin::AR::Connection`

The DB pool is the scarce resource everything else is sized against.

```ruby
Shaolin::AR::Connection.establish!(config, replica: nil)
#   config: plain hash (adapter/database/host/...); missing keys get ENV defaults:
#     pool:             Integer(ENV["DB_POOL"]              || 5)   # MUST be ≥ concurrent fibers/threads hitting the DB
#     checkout_timeout: Float(  ENV["DB_CHECKOUT_TIMEOUT"]  || 5)   # bound the wait for a free connection (s)
#     reaping_frequency:Integer(ENV["DB_REAPING_FREQUENCY"] || 60)  # reclaim leaked/dropped connections (s)
#   replica:  optional hash → read-replica via AR role routing (writing→primary, reading→replica)

Shaolin::AR::Connection.reading { Model.heavy_query }     # route reads to the replica (no-op passthrough if none)
Shaolin::AR::Connection.with_advisory_lock(key) { ... }   # pg_advisory_lock(key.to_i) around a critical section
Shaolin::AR::Connection.connected?                        # SELECT 1; true/false (rescues StandardError)
Shaolin::AR::Connection.isolation_level = :fiber          # :fiber under Falcon, :thread under Puma/worker
Shaolin::AR::Connection.isolation_level                   # => current ActiveSupport isolation level
```

`reading` only routes when a replica was wired (`replica:`/`replica_config:`); otherwise it
just `yield`s, so app code can wrap heavy reads unconditionally. **All writes** (event
append + sync projections + outbox enqueue) stay on the primary, so the atomic outbox is
unaffected.

Wired via the provider (which also sets isolation, schema, health, and the kernel backend):

```ruby
Shaolin::AR.register_provider!(config:, isolation_level: :thread,
                               auto_schema: true, replica_config: nil)
# Falcon entrypoint sets isolation_level: :fiber; the worker stays :thread.
# auto_schema: false in production — run `shaolin migrate` as a release step instead.
```

### Sizing relationships

```
SHAOLIN_WEB_CONCURRENCY  ≈  DB_POOL          (admission cap ≤ connections you actually have)
worker --threads         ≤  DB_POOL          (the worker's pool must cover its threads)
SHAOLIN_REQUEST_TIMEOUT  >  p99 handler time, but small enough to free connections fast
DB_CHECKOUT_TIMEOUT (5s) <  SHAOLIN_REQUEST_TIMEOUT   (fail the wait before the request deadline)
```

- **`DB_POOL`** must be `≥` the number of concurrent fibers (Falcon) or threads (worker)
  that hit the DB. Under Falcon, that ceiling is your admission cap; under the worker, it's
  `--threads N`.
- Set **`SHAOLIN_WEB_CONCURRENCY ≈ DB_POOL`**: shed (`503`) at the edge instead of letting
  fibers queue on `checkout_timeout` and slow-fail.
- Set **`SHAOLIN_REQUEST_TIMEOUT`** so a hung request gives its connection back; without it,
  one stuck handler permanently removes a connection from the pool.

---

## 7. Scale by replicas

The single-process knobs above are bounded by `DB_POOL` and CPU. To go bigger, **add
replicas** (more processes/containers), not bigger pools:

- Each replica is a process with its **own** `DB_POOL` and its **own** admission cap.
  Total DB connections = `replicas × DB_POOL` — keep that under your Postgres
  `max_connections` (use PgBouncer if it gets large).
- Boot is **safe under N concurrent replicas**: event-store and jobs schema creation are
  guarded by a Postgres advisory lock (`SCHEMA_LOCK_KEY = 7_283_010` via
  `with_advisory_lock`), so concurrent boots don't race.
- The transactional **outbox** is per-write-DB and atomic, so horizontal web scaling doesn't
  weaken delivery guarantees; scale the **worker** independently by `--threads` and replicas.
- Offload heavy/analytical reads to a **read replica** (`replica_config:` +
  `Shaolin::AR.reading { … }`) so they don't compete with the write path.
- Graceful shutdown is built in: `SIGTERM`/`SIGINT` → `adapter.stop(timeout: SHAOLIN_GRACEFUL_TIMEOUT)`
  (default 10s, matching Cloud Run's window), so a rolling deploy drains in-flight requests.

---

## 8. Metrics to watch — `Shaolin::HTTP::Metrics`

`GET /metrics` renders Prometheus text via `Shaolin::HTTP::Metrics.render` (always emits
`shaolin_up 1`, or `shaolin_up 0` if rendering raises).

| Series | Meaning | Alert when |
|---|---|---|
| `shaolin_db_pool{state="size\|busy\|idle\|waiting"}` | pool utilization | `busy` rides at `size` **and** `waiting` climbs → saturated (the cliff) |
| `shaolin_http_in_flight` | current in-flight requests | near `…concurrency_max` → you're load-shedding (`503`s) |
| `shaolin_http_concurrency_max` | the admission cap | reference for sizing |
| `shaolin_outbox_jobs{status="pending\|failed\|done\|dead"}` | outbox depth by status | `pending` backlog grows, `dead` > 0 |
| `shaolin_outbox_oldest_pending_seconds` | worker lag | climbs → worker can't keep up |

`shaolin_db_pool` is emitted only when ActiveRecord is connected; `shaolin_http_in_flight`/
`…_max` only when `"http.concurrency"` is registered (i.e. a cap is set); outbox series only
when `"jobs.outbox"` is wired. Size `SHAOLIN_WEB_CONCURRENCY` from observed `in_flight` and
`db_pool`.

The startup banner (`server.started`) logs the bounds for you at boot: `url`, `adapter`,
`env`, `db_pool`, `web_concurrency` (`"unbounded"` if unset), `graceful_timeout`.

---

## 9. ENV reference

| ENV var | Default | Effect |
|---|---|---|
| `DB_POOL` | `5` | ActiveRecord pool size; the scarce resource |
| `DB_CHECKOUT_TIMEOUT` | `5` | seconds to wait for a free connection before raising |
| `DB_REAPING_FREQUENCY` | `60` | seconds between reclaiming leaked/dropped connections |
| `SHAOLIN_WEB_CONCURRENCY` | _(unset → unbounded)_ | admission cap; set `≈ DB_POOL` to load-shed |
| `SHAOLIN_REQUEST_TIMEOUT` | _(unset → off)_ | per-request deadline (s), Float; Falcon only |
| `SHAOLIN_GRACEFUL_TIMEOUT` | `10` | shutdown drain window (s) |
| `SHAOLIN_SERVER` | `falcon` | adapter; `puma` opt-in (timeout middleware inert under Puma) |
| `SHAOLIN_ENV` | `development` | `production` disables boot-time schema/migrate |
| `HOST` / `PORT` | `0.0.0.0` / `8080` | bind address |

---

## 10. Production checklist

- [ ] **`DB_POOL`** set deliberately; `≥` worker `--threads`, and `replicas × DB_POOL` under Postgres `max_connections`.
- [ ] **`SHAOLIN_WEB_CONCURRENCY ≈ DB_POOL`** (or `max_concurrency:` on the `:http` provider) — admission control on.
- [ ] **`SHAOLIN_REQUEST_TIMEOUT`** set above p99 but tight enough to free hung connections (Falcon).
- [ ] **`DB_CHECKOUT_TIMEOUT` < `SHAOLIN_REQUEST_TIMEOUT`** so the pool wait fails before the request deadline.
- [ ] **Rate limit** wired with a **Redis** store (not `Store::Memory`); correct `key:` for IP vs identity; trusted proxy for `X-Forwarded-For`.
- [ ] **Circuit breaker** wrapping each outbound dependency (RabbitMQ/Redis/HTTP) with sane `threshold`/`reset_timeout`.
- [ ] **`auto_schema: false`** + `SHAOLIN_ENV=production`; run `shaolin migrate` as a release step.
- [ ] **`swagger: false`** unless you intend to expose docs.
- [ ] Scrape **`/metrics`**; alert on `db_pool` saturation, `in_flight` near max, outbox `pending`/`dead`/lag.
- [ ] Confirm `/health` and the **startup banner** (`web_concurrency` not `"unbounded"` if you meant to cap).
- [ ] Read replica (`replica_config:` + `Shaolin::AR.reading`) for heavy analytical reads, off the write path.
- [ ] `SHAOLIN_GRACEFUL_TIMEOUT` matched to your platform's SIGTERM window for clean rolling deploys.

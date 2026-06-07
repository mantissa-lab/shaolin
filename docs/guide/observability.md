# Observability: logging, metrics, health, context

shaolin ships one structured logger, a Prometheus exposition endpoint, liveness/readiness probes,
and two request-scoped value bags — all in `shaolin-core` and `shaolin-http`. Everything (HTTP,
worker, scheduler, commands, events, the LLM harness) logs through the same `Shaolin::Log`, and a
single request id correlates one line across the whole request/job.

| Concern | API | Endpoint |
|---|---|---|
| Structured logging | `Shaolin::Log` | — (stdout / sinks) |
| Metrics | `Shaolin::HTTP::Metrics` | `GET /metrics` |
| Liveness | static | `GET /healthz` |
| Readiness | `Shaolin::Health` | `GET /readyz` |
| Request-scoped values | `Shaolin::Context`, `Shaolin::Tenant` | — (middleware) |
| Request id + access log | `Shaolin::HTTP::RequestLogger` | — (middleware) |

---

## 1. `Shaolin::Log` — structured logging

`gems/shaolin-core/lib/shaolin/log.rb`. A module with singleton methods. Every record is a Hash with
`ts` (UTC ISO8601, ms precision), `level`, `msg`, plus the current tenant, the in-scope context, and
your fields — emitted to every registered **sink**.

```ruby
Shaolin::Log.info("order_placed", order_id: id, total: total)
Shaolin::Log.error("payment_failed", order_id: id, error: e.message)
```

### Levels

`LEVELS = %i[debug info warn error]` (ordered). A record is dropped if its level is below the configured
threshold.

| Method | Signature | Purpose |
|---|---|---|
| `Log.debug` | `debug(msg, **f)` | Emit at `:debug`. |
| `Log.info` | `info(msg, **f)` | Emit at `:info`. |
| `Log.warn` | `warn(msg, **f)` | Emit at `:warn`. |
| `Log.error` | `error(msg, **f)` | Emit at `:error`. |
| `Log.emit` | `emit(level, msg, **fields)` | Low-level: explicit level (used by `RequestLogger`). |

```ruby
status = 503
Shaolin::Log.emit(status >= 500 ? :error : :info, "request", status: status, path: "/orders")
```

`msg` is stringified (`msg.to_s`); field keys become record keys.

### Level configuration

| Method | Signature | Purpose |
|---|---|---|
| `Log.level` | `level` | Current threshold (memoized from `SHAOLIN_LOG_LEVEL`, default `:info`). |
| `Log.level=` | `level=(lvl)` | Set threshold; coerced via `to_sym`. |

```ruby
Shaolin::Log.level = :warn
Shaolin::Log.info("ignored")   # dropped
Shaolin::Log.error("kept")     # emitted
```

### `with(**fields)` — scoped context

Merges fields into every record emitted inside the block (fiber/thread-local), restoring the previous
context on exit (even on raise). This is how a request id or run id rides along.

```ruby
Shaolin::Log.with(request_id: "req-1", run_id: run.id) do
  Shaolin::Log.info("inside")    # carries request_id + run_id
end
Shaolin::Log.info("outside")     # no request_id
```

| Method | Signature | Purpose |
|---|---|---|
| `Log.context` | `context` | The raw fiber/thread-local field Hash (`Thread.current[:shaolin_log_context]`). |
| `Log.with` | `with(**fields) { ... }` | Merge fields for the block; restore after. |

Merge order inside `emit`: `tenant` → `Shaolin::Context.to_h` → `Log.context` → your `**fields` (later
wins). So explicit per-call fields override context, which overrides ambient `Context`.

### Sinks

A sink is anything responding to `call(record)`. Default sink is chosen by env: `Sinks::Stdout` when
`SHAOLIN_ENV == "production"`, else `Sinks::Pretty`.

| Method | Signature | Purpose |
|---|---|---|
| `Log.sinks` | `sinks` | Current sink list (lazily `[default_sink]`). |
| `Log.sinks=` | `sinks=(list)` | Replace the list (wrapped via `Array(list)`). |
| `Log.add_sink` | `add_sink(sink)` | Append a sink. |
| `Log.reset!` | `reset!` | Clear sinks, level, and thread-local context (test helper). |

```ruby
Shaolin::Log.sinks = [Shaolin::Log::Sinks::Stdout.new]   # replace
Shaolin::Log.add_sink(->(record) { audit << record })    # add any #call(record)
```

#### `Sinks::Stdout`

Production. One JSON object per line.

```ruby
Shaolin::Log::Sinks::Stdout.new            # → $stdout
Shaolin::Log::Sinks::Stdout.new(io)        # initialize(io = $stdout); call → io.puts(JSON.generate(record))
```

#### `Sinks::Pretty`

Dev. Compact human line: `ts LEVEL msg key=val key=val`. `FIXED = %i[ts level msg]` are positional;
all other keys render as `k=v`.

```ruby
Shaolin::Log::Sinks::Pretty.new            # initialize(io = $stdout)
# 2026-06-07T12:00:00.123Z INFO  order_placed order_id=42 total=9.99
```

#### `Sinks::Batch`

Base for DB/remote sinks: buffers and flushes in batches **off the hot path** so writes never block the
request/job. Thread-safe (Mutex).

```ruby
Shaolin::Log::Sinks::Batch.new(flush_size: 100, flush_interval: 5, &flusher)
```

| Param | Default | Meaning |
|---|---|---|
| `flush_size:` | `100` | Flush when the buffer reaches this many records. |
| `flush_interval:` | `5` | Seconds between background flushes (only with `start!`). |
| `&flusher` | — | Block `flusher.call(batch_array)` doing the batched write. |

| Method | Signature | Purpose |
|---|---|---|
| `Batch#call` | `call(record)` | Buffer; flush synchronously if size threshold hit. |
| `Batch#flush` | `flush` | Drain the buffer now (no-op if empty). |
| `Batch#start!` | `start!` | Spawn a background thread flushing every `flush_interval`s. |

```ruby
bq = Shaolin::Log::Sinks::Batch.new(flush_size: 500, flush_interval: 10) do |records|
  MyBigQueryClient.insert(rows: records)
end
bq.start!
Shaolin::Log.add_sink(bq)
```

### The firehose

| Method | Signature | Purpose |
|---|---|---|
| `Log.everything?` | `everything?` | True when `SHAOLIN_LOG_EVERYTHING` is `1` or `true`. |

When on, the command bus, query bus, and event store log **every** command, query, and domain event
(verbose by design). The event store remains the durable source of truth; this is for a full audit
trail in the log stream.

### Shipping to BigQuery (stdout → Cloud Logging → BigQuery)

On GCP, do **not** write a BigQuery sink. Log structured JSON to stdout (the production default); Cloud
Run / GKE forward stdout to Cloud Logging (each line → a structured `jsonPayload`), and a Log Router
sink exports to a BigQuery dataset — zero app code.

```bash
gcloud logging sinks create shaolin-bq \
  bigquery.googleapis.com/projects/PROJECT/datasets/DATASET \
  --log-filter='resource.type="cloud_run_revision" jsonPayload.msg!=""'
```

Use a `Sinks::Batch` → BigQuery sink only when you are **not** on GCP logging.

### Log ENV vars

| ENV | Values | Default | Effect |
|---|---|---|---|
| `SHAOLIN_ENV` | `production` / other | — | `production` → JSON `Sinks::Stdout`; else `Sinks::Pretty`. |
| `SHAOLIN_LOG_LEVEL` | `debug`/`info`/`warn`/`error` | `info` | Initial threshold for `Log.level`. |
| `SHAOLIN_LOG` | `off` | unset | `off` silences `emit` entirely (tests). |
| `SHAOLIN_LOG_EVERYTHING` | `1`/`true` | unset | Enables the command/query/event firehose. |

> **Gotchas.** `level`, `sinks`, and `everything?` read their ENV **once** and memoize (`level`/`sinks`
> lazily; `everything?` re-reads each call). Set ENV before first use, or call `Log.level=` / `Log.sinks=`
> explicitly. `SHAOLIN_LOG=off` short-circuits before level/context, so nothing is emitted at all.

---

## 2. `Shaolin::HTTP::Metrics` — Prometheus `/metrics`

`gems/shaolin-http/lib/shaolin/http/metrics.rb`. A `module_function` module rendering Prometheus text
exposition (format version `0.0.4`). Served at `GET /metrics` by the router. A baseline — apps add
domain series via their own exporter.

| Method | Signature | Purpose |
|---|---|---|
| `Metrics.render` | `render` | Full exposition string. Always emits `shaolin_up`; on any error returns just `shaolin_up 0\n`. |
| `Metrics.db_pool` | `db_pool(lines)` | Append DB pool gauges (no-op unless AR connected). |
| `Metrics.in_flight` | `in_flight(lines)` | Append in-flight/cap gauges (no-op unless `http.concurrency` registered). |
| `Metrics.outbox` | `outbox(lines)` | Append outbox depth + lag gauges (no-op unless `jobs.outbox` registered). |

```ruby
puts Shaolin::HTTP::Metrics.render
# # TYPE shaolin_up gauge
# shaolin_up 1
# # TYPE shaolin_db_pool gauge
# shaolin_db_pool{state="size"} 5
# ...
```

`render` calls `db_pool`, `in_flight`, `outbox` in order; each is independently guarded so a missing
subsystem just omits its series rather than failing the scrape.

### Series

| Series | Type | Labels / variants | Source | Present when |
|---|---|---|---|---|
| `shaolin_up` | gauge | — | constant `1` (`0` on render error) | always |
| `shaolin_db_pool` | gauge | `state="size\|busy\|idle\|waiting"` | `ActiveRecord::Base.connection_pool.stat` | AR loaded **and** connected |
| `shaolin_http_in_flight` | gauge | — | `Concurrency#in_flight` | `Shaolin::Kernel.key?("http.concurrency")` |
| `shaolin_http_concurrency_max` | gauge | — | `Concurrency#max` | same |
| `shaolin_outbox_jobs` | gauge | `status="pending\|failed\|done\|dead"` | `outbox.stats` (`fetch(status, 0)`) | `Shaolin::Kernel.key?("jobs.outbox")` |
| `shaolin_outbox_oldest_pending_seconds` | gauge | — | `outbox.oldest_pending_age` | same |

- **`shaolin_db_pool`** — connection-pool saturation signal. `busy` riding at `size` while `waiting`
  climbs means you're at the pool cliff. Missing values default to `0`.
- **`shaolin_http_in_flight` / `_max`** — admission control (`Shaolin::HTTP::Concurrency`, opt-in via
  `SHAOLIN_WEB_CONCURRENCY`). `in_flight` near `max` means you're load-shedding (503s). Size the cap
  (`≈ DB_POOL`) from observed `in_flight`.
- **`shaolin_outbox_jobs`** — queue depth by status. `oldest_pending_seconds` is worker lag: the age of
  the oldest still-due `pending` job, `0.0` when nothing is due (`outbox.oldest_pending_age`).

### What to alert on

| Alert | Condition | Why |
|---|---|---|
| Pool saturation | `shaolin_db_pool{state="waiting"} > 0` sustained, or `busy == size` | Pool cliff; requests queue/time out. |
| Load shedding | `shaolin_http_in_flight` ≈ `shaolin_http_concurrency_max` | Returning 503s; scale out or raise cap. |
| Outbox backlog | `shaolin_outbox_oldest_pending_seconds` growing | Worker can't keep up with enqueue rate. |
| Dead letters | `shaolin_outbox_jobs{status="dead"} > 0` | Jobs exhausted retries; inspect with `outbox.dead`. |
| Failures | `shaolin_outbox_jobs{status="failed"}` rising | Transient handler errors retrying. |
| Liveness | `shaolin_up == 0` or scrape fails | Render error / process unhealthy. |

> **Gotcha.** `shaolin_up 0` is also returned when *rendering itself* raises (the rescue in `render`),
> not only on a hard outage — treat it as "metrics subsystem unhappy."

---

## 3. Probes: `/healthz`, `/readyz`, `Shaolin::Health`

`gems/shaolin-core/lib/shaolin/health.rb` + router (`gems/shaolin-http/lib/shaolin/http/router.rb`).

### `/healthz` — liveness (static 200)

Always `200 {"status":"ok"}`. No dependency checks — "the process is up." Used by orchestrators to
decide whether to **restart** a replica.

```
GET /healthz → 200 {"status":"ok"}
```

### `/readyz` — readiness (runs `Health.status`)

Runs every registered check. `200 {"status":"ok",...}` if all pass, else `503 {"status":"unavailable",...}`.
Used to decide whether to **route traffic** — an orchestrator (k8s / Cloud Run) only sends requests to a
replica that can reach its dependencies.

```
GET /readyz → 200 {"status":"ok","checks":{"database":true,"redis":true}}
           or 503 {"status":"unavailable","checks":{"database":true,"redis":false}}
```

### `Shaolin::Health`

| Method | Signature | Purpose |
|---|---|---|
| `Health.register` | `register(name, &check)` | Register a named check; block returns truthy when reachable. Key is `name.to_s`. |
| `Health.checks` | `checks` | The registered-checks Hash. |
| `Health.status` | `status` | `[overall_ok, { "name" => bool, ... }]`. A check that raises counts as `false` (never escapes). |
| `Health.reset!` | `reset!` | Clear all checks (test helper). |

```ruby
Shaolin::Health.register("database") { Connection.connected? }
Shaolin::Health.register("redis")    { pool.with { |r| r.ping == "PONG" } }

ok, detail = Shaolin::Health.status
# => [true, { "database" => true, "redis" => true }]
```

Providers register checks at boot: `:active_record` → `"database"` (`Connection.connected?`), `:redis`
→ `"redis"` (a `PING`). With **no** checks registered, `status` is `[true, {}]` (ready).

> **Gotcha.** Registering twice under the same `name` overwrites. Checks should be cheap — `/readyz` runs
> all of them on every probe.

---

## 4. Request-scoped values + request-id correlation

Two fiber/thread-local bags carry values from middleware into controllers and logs. Under Falcon's fiber
scheduler `Thread.current` is fiber-local, so both are correct for threaded **and** fibered servers.

### `Shaolin::Context` — generic request-scoped bag

`gems/shaolin-core/lib/shaolin/context.rb`. `KEY = :shaolin_context`. Anything an auth/middleware layer
resolves (project id, identity, …). Values are merged into every `Shaolin::Log` record for free
correlation, and the HTTP layer **clears it at the end of each request** so values never leak across
requests on a reused fiber/thread.

| Method | Signature | Purpose |
|---|---|---|
| `Context.store` | `store` | The raw bag Hash (`Thread.current[KEY] ||= {}`). |
| `Context.[]` | `[](key)` | Read a value. |
| `Context.[]=` | `[]=(key, value)` | Write a value. |
| `Context.to_h` | `to_h` | A copy of the bag. |
| `Context.clear` | `clear` | Reset to `{}` (RequestLogger calls this per request). |
| `Context.with` | `with(**fields) { ... }` | Merge fields for the block; restore previous bag after (even on raise). |

```ruby
# in middleware / an authenticator:
Shaolin::Context[:project_id] = resolve(env["HTTP_AUTHORIZATION"])
Shaolin::Context[:identity]   = identity        # router's #guard does this

# in a controller action:
project_id = Shaolin::Context[:project_id]

Shaolin::Log.info("hit")   # record automatically includes project_id, identity
```

### `Shaolin::Tenant` — current tenant

`gems/shaolin-core/lib/shaolin/tenant.rb`. `KEY = :shaolin_current_tenant`. shaolin does **not** enforce
tenant isolation — you weave this value into aggregate ids / stream prefixes / read-model columns and
always filter reads by it. The framework only carries it; auto-attaches it to every log record (as
`tenant`) when set.

| Method | Signature | Purpose |
|---|---|---|
| `Tenant.current` | `current` | The current tenant id (nil by default). |
| `Tenant.current=` | `current=(id)` | Set it. |
| `Tenant.with` | `with(id) { ... }` | Run a block with the tenant set; restore previous after (even on raise). |

```ruby
# HTTP middleware (from header / JWT claim) or a reactor (from the event data):
Shaolin::Tenant.with("acme") do
  Shaolin::Log.info("scoped")     # record gains tenant: "acme"
  # ... scope ids / filter read models by Shaolin::Tenant.current ...
end
```

> **Gotcha.** `Tenant` carries the value only — isolation is enforced by **your** code that reads it.
> Set it per request/job and clear/restore it (use `with`) so it never bleeds into the next unit of work.

### `Shaolin::HTTP::RequestLogger` — request id + access log

`gems/shaolin-http/lib/shaolin/http/request_logger.rb`. Rack middleware. `REQUEST_ID_ENV =
"shaolin.request_id"`.

| Method | Signature | Purpose |
|---|---|---|
| `RequestLogger.new` | `new(app)` | Wrap the downstream Rack app. |
| `RequestLogger#call` | `call(env)` | Assign/propagate request id, run the request inside `Log.with(request_id:)`, log one record, clear `Context`. |

Per request it:

1. Takes the request id from inbound `X-Request-Id` (`env["HTTP_X_REQUEST_ID"]`) or generates a
   `SecureRandom.uuid`; stores it at `env["shaolin.request_id"]`.
2. Runs the app inside `Shaolin::Log.with(request_id: request_id)` — so **every** downstream log line
   (commands, events, queries) carries the same `request_id`.
3. Echoes it back as the `x-request-id` response header.
4. Emits one structured access-log record `msg: "request"` with `method`, `path`, `status`,
   `duration_ms` (monotonic clock, rounded to 0.1ms), and `error` when present.
5. In an `ensure`, calls `Shaolin::Context.clear` so app-set values (identity, project_id) don't leak.

Access-log level by status: `>= 500 → :error`, `>= 400 → :warn`, else `:info`. On a raised exception it
logs status `500` with `error: e.message` and re-raises. It also picks up a handled exception stashed by
an inner `ErrorBoundary` at `env["shaolin.error"]`.

```ruby
# correlate a client report to your logs by the echoed header:
# response: x-request-id: 1f2e... → query Cloud Logging for jsonPayload.request_id="1f2e..."
```

> **Correlation chain.** `RequestLogger` sets `request_id` in the log context → all nested
> `Shaolin::Log` calls inherit it → the same id is in the access log and the response header. Add
> `Shaolin::Tenant`/`Shaolin::Context` values and they ride along on every line too.

### Probe/middleware ENV

| ENV | Used by | Effect |
|---|---|---|
| `SHAOLIN_WEB_CONCURRENCY` | `Shaolin::HTTP::Concurrency` | Sets the admission cap (`max`); enables in-flight metrics. Set ≈ `DB_POOL`. |

Inbound header `X-Request-Id` is honored for request-id propagation across services.

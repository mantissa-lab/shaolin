# Configuration reference (all ENV + provider options)

> Code-grounded reference for every environment variable shaolin reads and every
> `register_provider!` option. Everything below is verified against `gems/*/lib`;
> nothing is invented. Configuration is **12-factor** (ENV) plus explicit provider
> registration in `config/boot.rb`.

---

## 1. Environment variables

Every `ENV[...]` / `ENV.fetch` read in `gems/*/lib`, with its default and meaning.

| ENV var | Default | Read by | Meaning |
|---|---|---|---|
| `SHAOLIN_ENV` | `development` | core/log, http/error_boundary, server, cli | `production` flips the log sink to JSON-stdout, hides error details (`ErrorBoundary`), forbids `db reset`. The server banner reports it via `ENV.fetch("SHAOLIN_ENV","development")`. |
| `SHAOLIN_LOG` | (unset) | core/log | `off` silences ALL logging (used in tests). |
| `SHAOLIN_LOG_LEVEL` | `info` | core/log | Minimum level: `debug`/`info`/`warn`/`error`. Records below it are dropped. |
| `SHAOLIN_LOG_EVERYTHING` | (unset) | core/log, cqrs | `1` or `true` enables the firehose: buses + event store log every command/query/event. cqrs subscribes a per-event log line. |
| `SHAOLIN_SKIP_BOOT` | (unset) | generated `config/boot.rb`, generated `spec_helper.rb` | Truthy skips `AppClass.boot!` at require-time (spec_helper sets it to `1`). |
| `SHAOLIN_LINT_STRICT` | (unset) | cli `lint` | `1` makes cross-module reach-in / outside-module warnings fail (same as `--strict`). |
| `SHAOLIN_WEB_CONCURRENCY` | (unset / `unbounded`) | http/provider, server banner | Integer cap on in-flight HTTP requests (admission control / load-shed 503). Unset = unbounded. Set ≈ `DB_POOL`. |
| `SHAOLIN_MAX_BODY_BYTES` | `1048576` (1 MiB) | http/rewindable_input | Max request body size; larger → 413 `payload_too_large`. |
| `SHAOLIN_SERVER` | `falcon` | server/config | Server adapter, symbolized: `falcon` (default, async) or `puma`. |
| `HOST` | `0.0.0.0` | server/config | Bind address. |
| `PORT` | `8080` | server/config | Bind port (Integer). |
| `SHAOLIN_GRACEFUL_TIMEOUT` | `10` | server/config | Seconds for graceful shutdown on SIGTERM/SIGINT (Integer). |
| `SHAOLIN_REQUEST_TIMEOUT` | (unset = off) | server/config | Per-request deadline in seconds (Float). Enforced on Falcon; on Puma use Rack::Timeout. |
| `DB_NAME` | `<app>_development` | generated `config/boot.rb` | Postgres database name. |
| `DB_USER` | `postgres` | generated `config/boot.rb` | Postgres username. |
| `DB_HOST` | `localhost` | generated `config/boot.rb` | Postgres host. |
| `DB_PORT` | `5432` | generated `config/boot.rb` | Postgres port (Integer). |
| `DB_POOL` | `5` | ar/connection, server banner | AR connection-pool size (Integer). Must be ≥ concurrent fibers/threads hitting the DB (e.g. `WORKER_CONCURRENCY`). |
| `DB_CHECKOUT_TIMEOUT` | `5` | ar/connection | Seconds to wait for a free connection (Float). |
| `DB_REAPING_FREQUENCY` | `60` | ar/connection | Seconds between reaping leaked connections (Integer). |
| `WORKER_CONCURRENCY` | `1` | cli `worker` | Worker thread count (Integer). Warns if it exceeds the DB pool. |
| `WORKER_BATCH` | `20` | cli `worker` | Outbox rows claimed per batch (Integer). |
| `WORKER_TX_PER_JOB` | (unset) | cli `worker` | `1` or `true` → one transaction (row lock) per job instead of per batch. Recommended for IO-bound jobs (LLM harness gates). |
| `REDIS_URL` | `redis://127.0.0.1:6379/0` | redis/connection | Redis connection URL (`Connection::DEFAULT_URL`). |
| `RABBITMQ_URL` | (unset) | rabbitmq publisher + consumer | AMQP URL for the messaging transport. |
| `OPENAI_API_KEY` | (unset) | llm/openai, llm/realtime/openai | OpenAI bearer token. Read ONLY from ENV, never hardcoded; `complete` raises `"OPENAI_API_KEY not set"` if missing (and no `transport:`). |
| `OPENAI_MODEL` | `gpt-4.1` | llm/provider | Default chat model when the `:llm` provider builds the default OpenAI client. |

**Gotchas**

- `SHAOLIN_LOG_EVERYTHING` accepts only `1`/`true` (anything else = off).
- `SHAOLIN_WEB_CONCURRENCY` is read in two layers: as the `:http` provider's default `max_concurrency` AND in the server banner string. An explicit `max_concurrency:` keyword overrides the ENV.
- `DB_*` host/name/user/port live in the generated `boot.rb` template, not the gems — they shape the `DATABASE` hash you pass to `AR.register_provider!(config:)`. `DB_POOL`/`DB_CHECKOUT_TIMEOUT`/`DB_REAPING_FREQUENCY` are read inside the gem as production-safe defaults merged under your `config`.
- `SHAOLIN_ENV=production` is checked by string equality in three independent spots; set it exactly to `production`.

---

## 2. Provider registration

Providers wire shared infra into `Shaolin::Kernel` at boot. The core primitive:

```ruby
Shaolin.register_provider(name, after: [], &block)   # gems/shaolin-core/.../provider.rb
```

- `name` — Symbol id (`:cqrs`, `:http`, …).
- `after:` — Array of provider names this one must start after (topological ordering).
- block — DSL with `start do …; stop do …` lifecycle hooks; `start_all` runs in order, `stop_all` in reverse.

Each gem exposes a thin `register_provider!` wrapper. **Order matters** even though `after:` exists in core — the shipped wrappers don't declare `after:`, so you must call them in dependency order in `boot.rb`. Recommended order: `:active_record` → `:cqrs` → `:jobs` → `:http` (+ `:redis`, `:llm`, `:realtime`, `:harness`).

### 2.1 `Shaolin::AR.register_provider!` — `:active_record`

```ruby
def self.register_provider!(config:, isolation_level: :thread,
                            auto_schema: true, replica_config: nil)
```

| Kwarg | Default | Meaning |
|---|---|---|
| `config:` | (required) | Plain hash (`adapter:/database:/host:/...`). Missing pool keys filled from `DB_POOL`/`DB_CHECKOUT_TIMEOUT`/`DB_REAPING_FREQUENCY`. |
| `isolation_level:` | `:thread` | `:thread` (Puma) or `:fiber` (Falcon) — sets `ActiveSupport::IsolatedExecutionState`. |
| `auto_schema:` | `true` | Create the event-store schema at boot (advisory-locked via `SCHEMA_LOCK_KEY = 7_283_010`). Set `false` in production; run `shaolin migrate` instead. |
| `replica_config:` | `nil` | Hash for a read-only replica (AR role routing). Reads opt in via `Shaolin::AR.reading { … }`; all writes stay on primary. |

Registers into the kernel: `cqrs.event_store_backend` (the durable `EventRepository`) and `cqrs.transaction` (a `->(&blk){ ActiveRecord::Base.transaction(&blk) }`). Also adds a `"database"` health check. **Register BEFORE `:cqrs`** — otherwise cqrs falls back to in-memory.

```ruby
Shaolin::AR.register_provider!(
  config: { adapter: "postgresql", database: "app_dev", host: "localhost" },
  isolation_level: :fiber, auto_schema: !ENV["SHAOLIN_ENV"].eql?("production")
)
```

### 2.2 `Shaolin::CQRS.register_provider!` — `:cqrs`

```ruby
def self.register_provider!   # no kwargs
```

Builds `cqrs.command_bus`, `cqrs.query_bus`, `cqrs.event_store`, `cqrs.aggregate_repository` and auto-wires every module's command handlers, query handlers, and (sync) projections. If `cqrs.event_store_backend` is present (from `:active_record`) it wraps it; otherwise `EventStore.in_memory`. Optional `cqrs.event_mapper` key enables upcasting. `cqrs.transaction` (if present) makes append + sync subscribers atomic. Async projections (`Projection.async`) are skipped here — the `:jobs` provider routes them through the outbox.

```ruby
Shaolin::CQRS.register_provider!
```

### 2.3 `Shaolin::Jobs.register_provider!` — `:jobs`

```ruby
def self.register_provider!   # no kwargs
```

Ensures the outbox table, registers `jobs.outbox`, and subscribes each module's **reactors** and **async projections** to the event store as enqueue callbacks — an outbox row is inserted in the SAME transaction as the event append (transactional outbox). Side effects run later in `shaolin worker`. Cross-module topic subscriptions are resolved to concrete event classes at boot and fail loud on a typo (`Shaolin::Error`). **Register AFTER `:active_record` and `:cqrs`.**

```ruby
Shaolin::Jobs.register_provider!
```

### 2.4 `Shaolin::HTTP.register_provider!` — `:http`

```ruby
def self.register_provider!(middleware: [], swagger: false,
                            modules_dir: nil, auth: {}, max_concurrency: nil)
```

| Kwarg | Default | Meaning |
|---|---|---|
| `middleware:` | `[]` | List of builders `->(app){ Mw.new(app) }`, inserted just before the router (auth/rate-limit/CORS). |
| `swagger:` | `false` | Serve OpenAPI at `GET /openapi.json` + Swagger UI at `GET /swagger`. Keep off in prod. |
| `modules_dir:` | `<cwd>/app/modules` | Where to scan controllers for DTO linking (only used when `swagger:`). |
| `auth:` | `{}` | Hash of `scheme => ->(env){ identity_or_nil }`. A route declaring an unregistered scheme fails fast at boot (`BootError`). |
| `max_concurrency:` | `ENV["SHAOLIN_WEB_CONCURRENCY"]` (or nil) | In-flight cap; over it, requests get 503 (load-shed). Explicit value overrides the ENV. |

Builds the Rack app and registers `http.app`. Middleware stack (outer→inner): `RequestLogger → ErrorBoundary → RewindableInput → [Concurrency?] → [your middleware] → router`. Built-in routes: `GET /healthz` (always 200), `GET /readyz` (runs `Shaolin::Health`, 503 if down), `GET /metrics` (Prometheus). **Register AFTER `:cqrs`.**

```ruby
Shaolin::HTTP.register_provider!(
  swagger: true,
  auth: { bearer: ->(env) { User.from_token(env["HTTP_AUTHORIZATION"]) } },
  middleware: [
    ->(app) { Shaolin::HTTP::RateLimit.new(app, store: Shaolin::Kernel["redis.store"], limit: 100, window: 60) }
  ]
)
```

### 2.5 `Shaolin::Redis.register_provider!` — `:redis`

```ruby
def self.register_provider!(url: Connection::DEFAULT_URL, namespace: "shaolin",
                            pool_size: 5, stream: "shaolin:events")
```

| Kwarg | Default | Meaning |
|---|---|---|
| `url:` | `ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")` | Redis URL. |
| `namespace:` | `"shaolin"` | Key prefix; cache uses `<ns>:cache`, store uses `<ns>:store`. |
| `pool_size:` | `5` | ConnectionPool size. |
| `stream:` | `"shaolin:events"` | Stream name for the `StreamPublisher`. |

Registers `redis.pool`, `redis.cache`, `cache.store` (alias of cache — the generic cache port), `redis.store`, `redis.publisher`, plus a `"redis"` health check. Order-independent (only needs the kernel).

```ruby
Shaolin::Redis.register_provider!(namespace: "myapp", pool_size: 10)
```

### 2.6 `Shaolin::LLM.register_provider!` — `:llm`

```ruby
def self.register_provider!(client: nil)
```

| Kwarg | Default | Meaning |
|---|---|---|
| `client:` | `nil` → `OpenAI.new(model: ENV.fetch("OPENAI_MODEL", "gpt-4.1"))` | The chat client; registered as `llm.client`. Pass an `InMemory` (or any `Client`) in tests. |

```ruby
Shaolin::LLM.register_provider!   # default OpenAI from OPENAI_API_KEY/OPENAI_MODEL
# tests:
Shaolin::LLM.register_provider!(client: Shaolin::LLM::InMemory.new(replies: ["hi"]))
```

### 2.7 `Shaolin::LLM::Realtime.register_provider!` — `:realtime`

```ruby
def self.register_provider!(client:)   # client is REQUIRED
```

| Kwarg | Default | Meaning |
|---|---|---|
| `client:` | (required) | Realtime client; registered as `realtime.client`. Use `Realtime::InMemory` in tests or `Realtime::OpenAI` (with an injected WebSocket transport) live. |

```ruby
Shaolin::LLM::Realtime.register_provider!(client: Shaolin::LLM::Realtime::InMemory.new)
```

### 2.8 `Shaolin::Harness.register_durable_provider!` — `:harness`

```ruby
def self.register_durable_provider!   # no kwargs
```

> Note: the harness provider is `register_durable_provider!` (NOT `register_provider!`).

Subscribes a `GateEntered → outbox` enqueuer so `shaolin worker` advances harness runs step-by-step (`Shaolin::Harness::DriveReactor`), crash-resumably. **Register AFTER `:active_record`, `:cqrs`, `:jobs`, `:llm`.** Run the worker with `WORKER_TX_PER_JOB=1` (each gate's LLM call is IO-bound — hold the row lock per job).

```ruby
Shaolin::Harness.register_durable_provider!
```

---

## 3. Constructors with config (non-provider)

These adapters read ENV/keyword config directly; useful when you build a client yourself rather than via a provider default.

### `Shaolin::LLM::OpenAI.new` — Chat Completions adapter

```ruby
def initialize(api_key: ENV["OPENAI_API_KEY"], model: "gpt-4.1",
               base: "https://api.openai.com/v1", transport: nil, reasoning_tag: nil,
               open_timeout: 15, read_timeout: 600, max_retries: 2,
               retry_backoff: [0.5, 2.0], default_params: {},
               max_concurrency: nil, tts_async: nil)
```

| Kwarg | Default | Meaning |
|---|---|---|
| `api_key:` | `ENV["OPENAI_API_KEY"]` | Bearer token. `complete` raises if nil/empty and no `transport:`. |
| `model:` | `"gpt-4.1"` | Default chat model. |
| `base:` | `"https://api.openai.com/v1"` | API base URL (point at a proxy / self-hosted). |
| `transport:` | `nil` | `->(path, body){}` stub for tests — bypasses the network. |
| `reasoning_tag:` | `nil` | e.g. `"think"` — lifts inline `<think>…</think>` into `Completion#reasoning`. |
| `open_timeout:` | `15` | Connect timeout (s). |
| `read_timeout:` | `600` | Read timeout (s) — generous for reasoning models. |
| `max_retries:` | `2` | Retries on transient failures only (5xx, timeouts, dropped sockets); 4xx never retry. `0` disables. |
| `retry_backoff:` | `[0.5, 2.0]` | Per-attempt sleep; reuses last element past its length. |
| `default_params:` | `{}` | Sampling params on every call (e.g. `{ max_tokens: 4096 }`); per-call `params:` override. |
| `max_concurrency:` | `nil` | Semaphore cap on in-flight calls; `complete` blocks past it. |
| `tts_async:` | `nil` | `{ result_path:, done:, poll_interval:, max_wait: }` for async TTS; nil = sync `/audio/speech`. |

```ruby
client = Shaolin::LLM::OpenAI.new(model: "gpt-4.1", default_params: { temperature: 0.2 })
client.complete(messages: [{ role: "user", content: "hi" }]) # => Completion
```

### `Shaolin::LLM::Realtime::OpenAI.new`

```ruby
def initialize(api_key: ENV["OPENAI_API_KEY"], model: "gpt-4o-realtime-preview", transport: nil)
```

`transport:` must respond to `#send(hash)`, `#on_message { |hash| }`, `#close`. `connect(model: nil, tools: [], instructions: nil)` returns a `Session`; raises if no transport injected.

### `Shaolin::HTTP::RateLimit.new` — middleware

```ruby
def initialize(app, store:, limit:, window: 60,
               key: ->(env) { env["HTTP_X_FORWARDED_FOR"]&.split(",")&.first&.strip ||
                              env["REMOTE_ADDR"] || "anon" })
```

| Kwarg | Default | Meaning |
|---|---|---|
| `store:` | (required) | Any `Shaolin::Store` (`redis.store` in prod, `Store::Memory` in tests). |
| `limit:` | (required) | Max requests per window. |
| `window:` | `60` | Window seconds; bucket TTL is `window * 2`. |
| `key:` | client IP (XFF→REMOTE_ADDR→`"anon"`) | `->(env){ id }` — swap to an identity for per-user limits. |

Over the limit → 429 with `Retry-After`. Wire via the `:http` provider's `middleware:`. Adds `x-ratelimit-limit` / `x-ratelimit-remaining` headers.

### `Shaolin::HTTP::Concurrency.new(app, max:)`

Admission control: over `max` concurrent requests → 503 `overloaded` (load-shed, not queue). Registered as `http.concurrency` so `/metrics` reports the in-flight gauge. The `:http` provider builds it automatically when `max_concurrency`/`SHAOLIN_WEB_CONCURRENCY` is set.

### `Shaolin::HTTP::RewindableInput.new(app, max_bytes: MAX_BODY_BYTES)`

Buffers streaming bodies and caps size; over `SHAOLIN_MAX_BODY_BYTES` (default 1 MiB) → 413.

### `Shaolin::HTTP::ErrorBoundary.new(app, expose_details: ENV["SHAOLIN_ENV"] != "production")`

Maps escaping exceptions to the JSON `{error:{code,message}}` contract. `WrongExpectedEventVersion` → 409, `Shaolin::CQRS::UnregisteredCommand` → 422, else 500 (generic message in production unless `expose_details`).

### `Shaolin::Server::Config.new(env: ENV)`

Reads `HOST`/`PORT`/`SHAOLIN_SERVER`/`SHAOLIN_GRACEFUL_TIMEOUT`/`SHAOLIN_REQUEST_TIMEOUT` (see table). Pass to `Shaolin::Server.run(rack_app, config: Config.new, adapter: nil)`.

### `Shaolin::Redis::Connection`

```ruby
Shaolin::Redis::Connection.pool(url: DEFAULT_URL, size: 5, timeout: 5)  # ConnectionPool
Shaolin::Redis::Connection.client(url: DEFAULT_URL)                     # single ::Redis (for blocking Pub/Sub)
```

### `Shaolin::AR::Connection`

```ruby
Shaolin::AR::Connection.establish!(config, replica: nil)  # connect (+ optional replica role routing)
Shaolin::AR::Connection.isolation_level = :fiber          # or :thread
Shaolin::AR::Connection.reading { … }                     # route reads to replica (no-op without one)
Shaolin::AR::Connection.with_advisory_lock(key) { … }     # cross-process critical section
Shaolin::AR::Connection.connected?                        # health check
```

---

## 4. Logging configuration (`Shaolin::Log`)

Driven by `SHAOLIN_LOG`, `SHAOLIN_LOG_LEVEL`, `SHAOLIN_LOG_EVERYTHING`, `SHAOLIN_ENV` (see table). Programmatic overrides:

```ruby
Shaolin::Log.level = :debug
Shaolin::Log.sinks = [Shaolin::Log::Sinks::Stdout.new]   # JSON-per-line (prod default)
Shaolin::Log.add_sink(Shaolin::Log::Sinks::Batch.new(flush_size: 100, flush_interval: 5) { |records| … }.tap(&:start!))
Shaolin::Log.with(request_id: "abc") { Shaolin::Log.info("hello", k: 1) }
```

- `LEVELS = %i[debug info warn error]`. Default sink: `Sinks::Pretty` in dev, `Sinks::Stdout` (JSON) when `SHAOLIN_ENV=production`.
- `Sinks::Batch#start!` spawns a flush thread; subclass for DB/remote targets.

# Changelog

All notable changes to shaolin. The framework is pre-1.0; gems share the `0.1.0` line and are not yet
published (consumed as path gems). For full usage see [`llms.txt`](llms.txt) and [`docs/`](docs/).

**For an agent already using shaolin:** this file is your "what changed" source. After pulling, run
`bundle update shaolin-*` in your app. The headline change is that the **transactional outbox is now
atomic by default** — re-read the Reliability section below and `docs/EVENTS.md`.

## [Unreleased]

### LLM HTTP timeouts — no more dropped replies on slow reasoning models (issue #6)

- `Shaolin::LLM::OpenAI.new` takes `open_timeout:` (default 15s) and `read_timeout:` (default **600s**),
  applied to the Net::HTTP connection. Net::HTTP's 60s default read timeout dropped single replies from
  reasoning models (Qwen `<think>`, o-series) with `Net::ReadTimeout`, failing the whole turn; the
  generous default fixes it out of the box and both are tunable per deployment — no more injecting a
  full custom `transport:` just to raise a timeout.

### Conversation read-side — `conversations_read` projection (issue #5)

- Opt-in `Shaolin::Conversation.register_read_model!` maintains a cross-user `conversations_read` table
  (`session_id, harness, stage, turn_count, last_turn_at, tags jsonb`) via a sync projection over the
  conversation events — so analytics / an offer engine / entitlement can query the whole user base
  (`in_stage("offer")`, `with_min_turns(n, since: today)`, `tags->>'geo'='DE'`) **without** driving the
  session. CQRS: the run stream is the write side; this is the read model. The query facade is
  registered as `conversations.read` in the Kernel (framework infra, read by any module — not a
  cross-module reach-in). App dimensions are stamped with `session.tag(geo:, variant:)` /
  `run.tag(...)` (from on_result/on_turn) or a declarative `tags { |run| {...} }` block, persisted as a
  `Tagged` event and projected onto the row's jsonb `tags`. Aggregation/metrics (EPC) stay app-side.

### Structured output (issue #4) + canned-reply gates (issue #3)

- **Structured output** — `Shaolin::LLM::Client#complete(…, response_format:)` passes OpenAI's
  `response_format` (`json_object` / `json_schema`) through; the parsed object surfaces on
  `Completion#data` (symbol keys; nil unless requested). Harness gates can declare it —
  `response_format { … }` — for classification/decision gates that want a typed verdict
  (`on_result { |out, run| … out.data[:verdict] … }`) instead of a pseudo-tool or free-text parsing.
  `Responded` events persist `data`; `InMemory` scripts carry `data:`.
- **Canned-reply gates** — `gate :refuse, reply: "…"` (or `reply { |run| … }`) emits fixed text as the
  turn's reply with **no LLM call** (refusals, nudges, scripted onboarding) — deterministic, zero
  tokens/latency. Tools/transitions still run via `on_result`. `examples/conversation`'s refuse gate is
  now canned.

### Conversational mode for harnesses — `Shaolin::Conversation` (issue #2)

- Harness generalized from "autonomous run-to-terminal" into **a state machine over LLM steps with two
  modes**: autonomous (input fixed at start, runs to a terminal gate, self-advancing) and **conversational**
  (a human message per turn, rests at an `await` gate between turns, never terminal). The two compose —
  a conversational *turn* is itself an autonomous mini-run that ends by resting at an await gate.
- Engine deltas in `shaolin-harness`: `Runner#receive(id, input:)` (records the inbound `MessageReceived`,
  wakes the run into the entry gate, runs the gate machine until it rests/terminates, persists the turn's
  `Replied` reply + fires `on_turn`); `gate :name, await: true` (a non-terminal resting state — `advance`
  is a no-op there, so a conversation never self-perpetuates); `Run` now accumulates chat `history`
  (`recent(n)` window) and a strict funnel `stage` (`advance_to` rejects undeclared transitions).
- New `Shaolin::Conversation` facade: `stages`/`edges` (strict, queryable funnel), `context`/`window`
  (persona + recent-window memory the prompt builder reads), `on_turn` (deterministic per-turn updates),
  and `Companion.session(id:, llm:, repo:, command_bus:)` → `session.receive(message)`. State updates
  ride tools=commands + on_result/on_turn (no reply-parsing). Deterministic tests via `LLM::InMemory`;
  `examples/conversation` mirrors a funnel companion bot.

### LLM reasoning is first-class on `Completion` (issue #1)

- `Shaolin::LLM::Completion` gains a **`reasoning`** field (+ `reasoning?`) alongside `text`/
  `tool_calls`/`usage`. `Shaolin::LLM::OpenAI#complete` maps a provider's `reasoning_content` (or
  `reasoning`) field into it automatically, and — **opt-in** via `OpenAI.new(reasoning_tag: "think")`
  — lifts an inline `<think>…</think>` block out of the content into `reasoning`, leaving `text`
  clean (for Qwen-style models that emit reasoning inline). Off by default, so other providers are
  unaffected. `InMemory` scripted completions can carry `reasoning` for deterministic harness tests.
  The harness `Responded` event now persists `reasoning`, so the model's thinking is auditable/
  replayable in the run's event log while only clean `text` is shown to users.

### Umbrella gem: `gem "shaolin"` + `require "shaolin"`

- New meta-gem **`shaolin`** (like the `rails` gem) depends on the whole stack and `require "shaolin"`
  loads it — so an app's `Gemfile` is one line (`gem "shaolin"`) and `config/boot.rb` is one require,
  instead of listing/requiring each sub-gem. It pins every sub-gem to its exact version so the framework
  moves in lockstep, and pulls **everything** (core, cqrs, activerecord, dto, http, server, jobs,
  messaging, redis, rabbitmq, llm, harness) plus the `shaolin` CLI. The CLI command stack (Thor/Prism)
  is a dependency — so the `shaolin` binary installs — but is **not** required into a booted app/worker.
  Generated apps use it now (`shaolin new` Gemfile + boot). Caveat: the one-line Gemfile applies to a
  **published** consumer; the local path-gem build (`--path`) still lists every sub-gem by path, because
  Bundler doesn't resolve a path gem's dependencies as paths transitively.

### Migration drift detection (catches an edited applied migration)

- `Shaolin::AR::Migrator.run` (used by `shaolin migrate` and dev boot's `migrate!`) now stores a SHA-256
  checksum of every applied migration in a `shaolin_migration_checksums` table and **raises before
  migrating** if an already-applied migration's file later changes on disk. This was a real foot-gun
  (agent feedback): editing an applied migration is a silent divergence — the version is already in
  `schema_migrations`, so the change never re-runs on a persistent/prod DB, while a fresh dev DB and
  `shaolin db reset` hide it. The error names the drifted file and tells you what to do (`shaolin db
  reset` in dev to re-apply from scratch; in prod, revert and add a NEW migration). Unapplied migrations
  are free to change. The first run after upgrading blesses existing applied migrations at their current
  content; edits after that are caught. `shaolin db reset` clears the checksum table with everything else.

### `import("…")` now works in reactors (and any service object)

- `Shaolin::Jobs::Reactor` now `include Shaolin::Imports`, so a reactor block resolves another module's
  component with the same lint-checked `import("other.key")` as controllers and command/query handlers —
  no more hand-navigating `Kernel["kernel.containers"][...]` (which also bypassed the static
  `undeclared-import` lint). Any exported **service object** can opt in the same way: `include
  Shaolin::Imports`. `shaolin lint` already scans every `*.rb` under a module (including `reactors/`),
  so these calls are validated against the manifest everywhere.

### ⚠️ Generator default changed: CRUD, not event-sourcing

- `shaolin g module <name>` now scaffolds a **plain CRUD module** by default (model + DTO + controller +
  migration). Event sourcing is **opt-in via `--es`** (the full CQRS command/event/aggregate/projection/
  read-model). Rationale (agent feedback): ES is powerful but heavy; the path of least resistance
  shouldn't push you into ~11 files for CRUD-shaped data. ES machinery stays first-class — you pay its
  ceremony when you ask. `--reactor` now requires `--es`. Already-generated apps are unaffected.

### LLM harness (`shaolin-llm` + `shaolin-harness`)

- **`shaolin-llm`** — provider-agnostic chat-completion port (`Shaolin::LLM::Client#complete`) with
  `InMemory` (scripted, records calls — deterministic tests, no network) and `OpenAI` (stdlib Net::HTTP,
  key only from `ENV["OPENAI_API_KEY"]`, injectable transport; live tests opt-in via `RUN_LIVE`). The
  `:llm` provider registers `llm.client`.
- **Realtime/audio substrate** (`Shaolin::LLM::Realtime`) — provider-agnostic, so you can build realtime
  on ANY backend (not just OpenAI): normalized session `Event`s (`session_started`/`transcript_delta`/
  `audio_delta`/`tool_call`/`turn_completed`/`error`/`session_closed`), `Audio` helpers (PCM16/base64,
  framing), a `Session`/`Client` port (`send_audio`/`send_text`/`commit`/`tool_result`/`close` +
  `on_event`), an `InMemory` adapter (scriptable — build & test voice/tool flows with no provider/network),
  and an `OpenAI` adapter mapping the Realtime WebSocket wire events both ways via an injectable transport
  (unit-tested without a network; bring a WebSocket gem for the live socket). Example: `examples/realtime`.
- **`shaolin-harness`** — build LLM harnesses as **event-sourced gate state machines**. A
  `Shaolin::Harness` subclass declares `gate`s (entry/terminal) with a `prompt`, allowed `tools` (mapped
  to **commands on the command bus**), and an `on_result` that transitions/completes. Every step
  (prompt, response, tool call, transition) is a domain event → full audit, crash-resume, deterministic
  replay with the InMemory LLM.
  - Two runtimes: **sync** (`run_to_completion`) and **durable** (`start` + `advance` per gate — each
    advance is one atomic step with LLM/tool IO outside the transaction, so a fresh Runner resumes a
    run purely from its event stream).
  - **Worker-driven durable loop**: `Shaolin::Harness.register_durable_provider!` subscribes a
    `GateEntered` → outbox enqueuer, so `shaolin worker` advances a run gate-by-gate; each advance
    enqueues the next gate's job (the loop self-perpetuates, crash-resumable). The `DriveReactor` is
    idempotent under at-least-once (skips a stale/duplicate GateEntered and terminal runs). Run the
    worker with `WORKER_TX_PER_JOB=1` (each gate's LLM call is IO-bound).
  - `Harness.describe` → machine-readable gate/tool/model map. Gates take an optional `to:` (declared
    next gates, for visualization — runtime transitions are still whatever `on_result` calls).
    `shaolin describe --json` lists harnesses (from `app/harnesses/**` and `app/modules/*/harnesses/**`)
    with gates/tools/model/edges; `shaolin graph` draws the gate graph. Example: `examples/harness/verify.rb`
    (sync + resume + worker-driven, all on the InMemory stub).

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
- **Cross-module reactors (by topic, isolation-clean)**: a reactor in module B can react to module A's
  event via the dotted **topic string** — `on("orders.order_placed") { |e| … }` — declared in the
  manifest as `imports events: ["orders.order_placed"]`. No reference to A's class, so `lint` stays
  clean; the `:jobs` provider resolves the topic to its event class at wire time, the enqueue is atomic
  with A's event, and the worker dispatches it normally. `describe --json` shows the reactor's `topics`
  and the module's `events_subscribed`; `graph` shows the `B -> A` edge. See `examples/cross_module`.
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

### OpenAPI

- **`shaolin openapi [--out FILE]`** — generates an **OpenAPI 3.1** document from a booted app: paths /
  methods / `operationId` / path params (`{id}`) from each controller's `route_set`; **request-body
  schemas from the DTO each action validates** (linked by a static scan for `SomeDTO.validate`, then
  dry-schema's `:json_schema` extension — types, required, constraints, for free); standard status codes
  + the shared `Error` schema from the Result→HTTP contract. OpenAPI 3.1 aligns with JSON Schema, so DTO
  schemas drop in directly; paths are correctly templatized (the gap rspec-openapi couldn't fill without
  Rails). Response bodies are generic in v1.
- **Tags + response schemas** (agent feedback): every operation is now tagged by its module (`tags:
  ["conversions"]`) so Swagger UI groups by resource instead of one "default" bucket. Document a response
  body by annotating the route — `get "/x/:id", :show, response: SomeView` (a DTO/view class → 200),
  `response: [SomeView]` for a **collection** (`{type: array, items}` — list/index endpoints), or
  `response: { 201 => View }` for several statuses; the schema lands in `responses.<code>.content`.
- **Served live**: `Shaolin::HTTP.register_provider!(swagger: true)` serves the spec at `GET /openapi.json`
  and interactive **Swagger UI at `GET /swagger`** (generated at boot). Generated apps enable it in dev
  (`!production`) out of the box; off by default in production. The generator lives in `shaolin-http`
  (`Shaolin::HTTP::OpenAPI`); the `shaolin openapi` CLI reuses it.

### Agent-review papercuts (round 2)

- **`Shaolin::Store` port + `Store::Memory`** — in-memory key-value/hash store for tests (mirrors
  `Redis::Store`, JSON round-trip → symbol keys); `Redis::Store` now implements the port.
- **DTO coerces integer → `:float`** (`json.float` = coercible.float); `:string` stays strict.
- **`shaolin db reset`** (DEV): drop + create + migrate via a maintenance connection; refuses under
  `SHAOLIN_ENV=production`. Ends the manual drop/recreate dance when a migration changes.
- **One inflector** (`Shaolin::Inflector`) shared by the generator (Naming) and the zeitwerk autoloader —
  fixes the latent acronym divergence the migration bug symptomized (`url_maps` is `URLMaps` in both now).
- **`shaolin g field MODULE name:type`** — generates the add_column migration (CRUD table or ES read
  model) + an explicit edit checklist for the rest (no fragile auto-rewrite of existing Ruby).
- **`Shaolin::Keys.deep_symbolize`** for the jsonb edge; event data is guaranteed symbol-keyed even when
  nested (test locks it through the AR store).
- **`import("other.thing")`** (`Shaolin::Imports`, mixed into controllers/handlers) — validated
  cross-module access via the module's own container instead of `Kernel["kernel.containers"][...][...]`;
  a clear error (not a runtime nil) for an undeclared key, and `shaolin lint` flags undeclared `import`s
  statically (`undeclared-import`).

### Fixes & DX (from downstream-agent feedback)

- **BUG fixed — migration class name on acronym namespaces.** `g module api_keys` generated
  `class CreateAPIKeysRead` (dry-inflector namespace `APIKeys`) but ActiveRecord's MigrationContext
  looks up `CreateApiKeysRead` (ActiveSupport camelize of the filename) → boot crashed with NameError.
  The generator now names the migration class to match AR's filename→constant rule; module namespaces
  stay acronym-cased (`APIKeys`) for zeitwerk.
- **Worker batching configurable.** `WORKER_BATCH` (default 20) bounds jobs per drain; new
  `WORKER_TX_PER_JOB=1` (Worker `tx_per_job:`) commits each job in its own short transaction — for
  IO-bound reactors (outbound HTTP) a slow call now holds a row lock for just that job, not the batch.
- **`Shaolin::Context`** — the blessed middleware→controller channel: a fiber/thread-local request bag
  (`Shaolin::Context[:project_id] = …` in middleware → read in the action), cleared per request and
  auto-merged into logs. `request.env` is also exposed read-only.
- **`Shaolin::Testing`** — DB isolation for specs: `install(config, only: :integration)` truncates read
  models + event store + outbox before each integration example (wired into the generated spec_helper).
- **`Shaolin::Id.deterministic(*keys)`** — stable v5-style UUID from business keys for idempotent
  ingest; `Shaolin::Id.generate` for random ids.

### Logging (`Shaolin::Log`)

- **Unified structured logger** that everything routes through (HTTP access line, worker, scheduler,
  and app code): `Shaolin::Log.info("msg", **fields)` / `warn` / `error` / `debug`. JSON in production
  (`Sinks::Stdout`), human-readable in dev (`Sinks::Pretty`); leveled via `SHAOLIN_LOG_LEVEL`.
- **Context correlation**: `Shaolin::Log.with(run_id:) { ... }` plus auto-attached tenant and request_id
  thread/fiber-local, so one line ties a whole request/job together.
- **Pluggable sinks** (`#call(record)`); `Sinks::Batch` buffers + flushes off the hot path for DB sinks.
- **Firehose**: `SHAOLIN_LOG_EVERYTHING=1` logs every command, query, and domain event (the event store
  remains the durable source of truth).
- **Ship to BigQuery the easy way** (GCP): structured stdout → Cloud Logging → a Log Router BigQuery
  sink, zero app code. `docs/LOGGING.md` has the setup (and a direct `Batch` sink for non-GCP).
- `RequestLogger` (HTTP) and the worker/scheduler logs now flow through `Shaolin::Log`.

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
- `examples/cross_module` — module B reacts to module A's event by topic (`verify.rb`).
- `examples/harness` — LLM harness: gates + tool=command, sync + durable + worker-driven (`verify.rb`).
- `examples/realtime` — provider-agnostic realtime voice loop on the InMemory adapter (`verify.rb`).

## Gems

`shaolin-core`, `-cqrs`, `-activerecord`, `-dto`, `-http`, `-server`, `-cli`, `-messaging`, `-jobs`,
`-rabbitmq`, `-redis`, `-llm`, `-harness` (13). Optional transports/integrations (`-rabbitmq`, `-redis`,
`-llm`, `-harness`) are added as needed.

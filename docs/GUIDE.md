# shaolin — overview guide

> **This is the single-file overview.** For the full per-topic reference (one page per gem/area, every
> public API, generated from the code), see [`guide/`](guide/README.md). This guide + that tree +
> [`../llms.txt`](../llms.txt) + [`../CHANGELOG.md`](../CHANGELOG.md) are the **current** source of truth,
> grounded in the code. The design specs under `docs/superpowers/specs/` are **historical** pre-build
> documents and may be stale — prefer these.

shaolin is a **standalone, modular CQRS / Event-Sourcing backend framework for Ruby 4.0+** (not Rails,
but Rails-ecosystem gems — ActiveRecord first — work). It's built to be **operated by AI agents**:
deterministic conventions, generators, explicit `require`s, machine-readable contracts, and lint-enforced
module isolation. Distributed as a private git gem (umbrella `shaolin`).

---

## 1. Mental model

- **A module is a folder** (`app/modules/<name>/`) — a bounded context with an explicit public contract
  (`module.rb` manifest). Isolation is **enforced**: a module may only reach another via declared
  `imports`/`exports`. `shaolin lint` fails on reach-ins.
- **CQRS + Event Sourcing core.** Commands mutate event-sourced **aggregates**; **events** are the source
  of truth (Postgres event store via ruby_event_store); **projections** build **read models** you query.
- **Kernel + providers.** A small `Shaolin::Kernel` holds shared infra (`cqrs.*`, `http.app`, `jobs.outbox`,
  …). Providers (`:active_record`, `:cqrs`, `:http`, `:jobs`, `:llm`, `:redis`, …) wire it at boot, in order.
- **Transports are thin adapters** over the same command/query buses: HTTP controller, RabbitMQ consumer,
  CLI. Run a modular monolith, or flip on messaging for microservices.
- **Atomic transactional outbox** is the headline reliability property: an event append, its synchronous
  projections, and the async-reactor enqueue all commit in **one** transaction.

---

## 2. Install & layout

shaolin ships via (private) git, not RubyGems. One line pulls the whole framework (Bundler `glob:` exposes
every sub-gem's gemspec):

```ruby
# Gemfile
gem "shaolin", git: "https://github.com/mantissa-lab/shaolin.git", tag: "v0.1.0", glob: "gems/*/*.gemspec"
```
```ruby
# config/boot.rb  — one require loads core, cqrs, activerecord, dto, http, server, jobs, messaging,
# redis, rabbitmq, llm, harness (NOT the CLI, which is a dev/binary tool)
require "shaolin"
```

`shaolin new <app>` scaffolds this. Generated layout:

```
app/modules/<name>/        # bounded-context modules (the only enforced-isolation code)
config/boot.rb             # require "shaolin" + provider registration + AppClass.boot!
bin/server                 # falcon/puma entrypoint
app/harnesses/             # LLM harnesses/conversations (optional)
spec/                      # RSpec
Dockerfile, deploy/service.yaml   # GCP/Knative
```

**Isolation scope (#17):** `shaolin lint` analyzes `app/modules/**` for cross-module reach-ins, AND warns
on code **outside** modules (anything but `config/`, `bin/`, `spec/`, vendor + repo-root entrypoints) that
reads `Shaolin::Kernel[...]` or another module's constants. `--strict` (`SHAOLIN_LINT_STRICT=1`) makes those
fail CI. **Best practice:** put orchestration in a module, not a loose `app/telegram/` dir.

---

## 3. Dev vs prod

`SHAOLIN_ENV=production` flips the boot: no `auto_schema`, no auto-migrate, no Swagger. In dev all three
are on for a zero-step start.

| | dev (default) | production |
|---|---|---|
| Schema | `auto_schema: true` (created at boot) | `shaolin migrate` (release step) |
| Read-model migrations | auto on boot | `shaolin migrate` |
| Swagger UI | `/swagger` + `/openapi.json` on | off |

---

## 4. CLI (`shaolin <cmd>`)

```
new APP                         scaffold an app
g module NAME                   plain CRUD module (default)
g module NAME --es              event-sourced CQRS module
g module NAME --es --reactor    + an async reactor
g field MODULE name:type        add a field (migration + edit checklist)
server                          serve HTTP (Falcon default)
console                         IRB with the app booted
migrate                         apply event-store + jobs schema + read-model migrations (release step)
db reset                        drop + create + migrate (DEV ONLY)
rollback [STEPS]                roll back read-model migrations
worker                          process the outbox (async reactors / async projections)
scheduler                       run periodic tasks (single leader via advisory lock)
jobs [stats|dead|retry ID]      inspect the outbox
projections rebuild [NAME]      replay events into read models
describe [--json]               machine-readable map of the app
schemas                         each module's command/event surface
openapi [--out FILE]            OpenAPI 3.1 document
lint [--strict]                 module isolation check
graph                           module dependency graph
routes                          modules + exposed commands/events
```

---

## 5. Modules

`shaolin g module orders` (CRUD) or `--es` (CQRS/ES). Inflection: `orders` → namespace `Orders`, entity
`Order`; with `--es` also `CreateOrder`, `OrderCreated`, read model `orders_read`, topic `orders.order_created`.

**CRUD module:** `<entity>.rb` (ActiveRecord model) · `dto/` · `controllers/` · `db/migrate/` · `CONTRACT.md`.

**`--es` module:** adds `commands/` · `events/` · `<entity>.rb` as an event-sourced aggregate ·
`command_handlers/` · `projections/` · `read_models/` · `queries/`.

**Manifest** (`module.rb`):
```ruby
Shaolin.module("notifications") do
  imports "billing.invoice_reader"            # another module's exported component (validated)
  imports events: ["orders.order_placed"]     # subscribe to another module's event by topic
  events_published "notifications.sent"        # what this module emits cross-module
end
```

**Rules for changing a module (best practice):**
1. Stay in one folder. Cross-module access only via `import("other.key")` (controllers, handlers,
   reactors, or any class that `include Shaolin::Imports`). Never `Shaolin::Kernel[...]` from app code.
2. React to another module's events by **topic string** (`on("orders.order_placed")` + `imports events:`),
   never its event class.
3. `require_relative` siblings (no autoloading magic across modules; zeitwerk within a module).
4. To add a field: edit the command, event, DTO, aggregate, projection, read-model migration together.

---

## 6. The flow

```
HTTP request → DTO.validate → Command (value object) → command bus → CommandHandler
  → Aggregate (event-sourced) emits a domain Event → Event store (Postgres)
  → Projection updates a read model
GET → query bus → QueryHandler → read model → JSON
```
Write and read are separated (CQRS); state is rebuilt by replaying events (ES).

---

## 7. Layer reference

### DTO (`shaolin-dto`)
```ruby
class CreatePostDTO < Shaolin::DTO
  json { required(:title).filled(:string); optional(:views).filled(:json_float) }
end
CreatePostDTO.validate(params) # => Result#success?/#failure?/#to_h/#errors
```
`json_float` coerces int→float. DTOs feed OpenAPI request schemas automatically.

### HTTP (`shaolin-http`)
```ruby
class PostsController < Shaolin::HTTP::Controller
  routes do
    post "/posts",     :create, response: Views::PostView                 # response: → OpenAPI
    get  "/posts/:id", :show,   response: Views::PostView
    get  "/posts",     :index,  response: [Views::PostView]               # array schema
    post "/admin/x",   :secret, auth: :admin                              # per-route auth (#18)
  end
  # default_auth :admin   # controller-wide default

  def create(req)
    result = CreatePostDTO.validate(req.params)
    return unprocessable(result.errors) if result.failure?
    render_result(command_bus.call(CreatePost.new(**result.to_h)), location: "/posts/...")
  end
  def show(req) = json(Queries::FindPost.new(id: req[:id]) |> query_bus.method(:call))
end
```
- **Request:** `req.params` (router path params + body, symbol keys) parses JSON, `multipart/form-data`,
  `x-www-form-urlencoded`; `req.files` (uploads: `{filename:, type:, bytes:, tempfile:}`); `req.cookies`;
  `req.env`. (#8/#12)
- **Response (#13):** actions return a `Shaolin::HTTP::Response` — `json`/`text`/`created`/`no_content`/
  `render_result` build it; chain `.cookie(name, value, **opts)` (HttpOnly/SameSite=Lax/Secure defaults),
  `.delete_cookie`, `.header(k,v)`; or `json(data, status:, headers:, cookies:)`. Raw Rack tuples still work.
- **`render_result`** maps dry-monads `Result` → HTTP (Success→200/201, `:not_found`→404, `:conflict`→409,
  else 422). Error envelope: `{ error: { code:, message: } }`.
- **Buses** (`command_bus`/`query_bus`/`event_store`) resolve lazily from the kernel — available in actions.
- **Auth (#18):** `auth: :scheme` runs a registered authenticator before the action, 401s on nil identity,
  exposes it via `Shaolin::Context[:identity]`. Register: `HTTP.register_provider!(auth: { admin: ->(env){id|nil} })`.
  Boot fails if a route names an unregistered scheme.

### CQRS (`shaolin-cqrs`)
```ruby
class Post < Shaolin::CQRS::Aggregate
  def create(title:) = apply(Events::PostCreated.new(data: { id: id, title: title }))
  on(Events::PostCreated) { |e| @title = e.data[:title] }
end

class CreatePostHandler < Shaolin::CQRS::CommandHandler
  handles CreatePost
  def call(cmd) = aggregate_repository.unit_of_work(Post.new(cmd.id)) { |p| p.create(title: cmd.title) }
end

class PostsProjection < Shaolin::CQRS::Projection
  on(Events::PostCreated) { |e| ReadModels::PostRecord.project(id: e.data[:id]) { |r| r.title = e.data[:title] } }
end

class FindPostHandler < Shaolin::CQRS::QueryHandler
  handles Queries::FindPost
  def call(q) = ReadModels::PostRecord.find_by(id: q.id)&.attributes
end
```
- `unit_of_work` wraps append + sync projections + outbox enqueue in **one transaction** (atomic outbox).
- **Async projection (#22):** add `async` to a projection class — it runs OFF the append tx, driven by
  `shaolin worker` (eventually consistent, append-only write latency; requires `:jobs` + worker). Sync is
  default. Use async for heavy/non-read-your-write read models.
- **Rebuild (#26):** `shaolin projections rebuild [name]`; `ProjectionRunner.rebuild(es, projection, after:)`
  is resumable (returns the last-processed id; checkpoint + restart for huge streams; parallel per module).

### ActiveRecord (`shaolin-activerecord`)
- **Read model base:** `Shaolin::AR::ReadModel` — `project(id:) { |r| ... }` is an idempotent upsert
  (replay-safe; projections set absolute state, not increment).
- **Migrations** are per-module (`db/migrate/`). `shaolin migrate` applies them (release step). **Drift
  detection:** editing an *applied* migration raises (`shaolin_migration_checksums`) — the change would
  never reach a DB where the version is already in `schema_migrations`. dev: `shaolin db reset`; prod: add
  a new migration.
- **Event store:** Postgres via `ruby_event_store-active_record` (binary+YAML serializer for symbol-key
  round-trip), `FOR UPDATE SKIP LOCKED`, advisory locks.
- **Read replica (#27):** `AR.register_provider!(config:, replica_config:)`; writes stay on primary
  (atomic outbox intact); `Shaolin::AR.reading { ReadModels::Big.where(...) }` routes a block's reads to
  the replica (no-op without one).
- **Testing:** `Shaolin::Testing.install(rspec, only: :integration)` truncates app tables between examples.

### Jobs / outbox / worker / scheduler (`shaolin-jobs`)
```ruby
class NotifyReactor < Shaolin::Jobs::Reactor
  on(Events::PostCreated)         { |e| import("email.sender").deliver(e.data[:id]) }  # own module
  on("orders.order_placed")       { |e| ... }                                          # another module (topic)
end
```
- A **reactor** is an async side effect (email, publish, outbound HTTP). Its enqueue is **atomic** with the
  event (sync subscriber inserts an outbox row in the append tx); the side effect runs later in
  `shaolin worker`. **At-least-once → reactors must be idempotent.**
- **Worker:** claims due jobs (`FOR UPDATE SKIP LOCKED`), runs the reactor, retries with backoff,
  dead-letters after max attempts. `WORKER_CONCURRENCY` (threads), `WORKER_BATCH`, `WORKER_TX_PER_JOB=1`
  (per-job tx — for IO-bound reactors). Woken by `LISTEN/NOTIFY` on enqueue (poll is the floor) (#23).
- **Scheduler:** `Shaolin.schedule "name", every: "1m" do ... end`; single leader across replicas via a
  Postgres advisory lock. `shaolin scheduler`.
- Run the harness/async-projection worker with `WORKER_TX_PER_JOB=1`.

### Messaging + RabbitMQ (`shaolin-messaging`, `shaolin-rabbitmq`)
- `Shaolin::Messaging::Publisher` port + `IntegrationEvent` envelope; `InMemoryPublisher` for tests.
- `Shaolin::RabbitMQ::Publisher` (bunny, pure Ruby) implements the port; `Consumer` turns messages into
  commands. `Publisher.new(breaker: Shaolin::CircuitBreaker.new)` fast-fails during a broker brownout (#25).

### Redis (`shaolin-redis`)
- **Cache** (`Shaolin::Cache` port + `Cache::Memory`): `fetch`/`write`/`read`/`delete` with server TTL.
- **Store** (`Shaolin::Store` port + `Store::Memory`): KV/hash/counters; `increment(key, ttl:)` (atomic
  fixed-window counter). Redis-as-DB.
- **Broker:** Redis Streams publisher (drop-in for the Messaging port) + consumer groups, and Pub/Sub.
- `Redis.register_provider!(url:, namespace:)` → `redis.cache`/`cache.store`/`redis.store`/`redis.publisher`.

### LLM (`shaolin-llm`)
```ruby
client = Shaolin::Kernel["llm.client"]   # or Shaolin::LLM::OpenAI.new(...)
c = client.complete(messages:, tools:, response_format:, params: { max_tokens: 4096 })
c.text; c.reasoning; c.tool_calls; c.usage; c.data; c.finish_reason; c.truncated?
client.speak(text, voice:, format:)      # TTS → audio bytes
client.transcribe(audio_bytes, language:) # STT → text
```
`OpenAI.new` knobs: `reasoning_tag: "think"` (lift inline `<think>` → `reasoning`, clean `text`),
`response_format:`/`default_params:` (sampling; `params:` per call overrides), `open_timeout:`/`read_timeout:`
(default 600s — slow reasoning models), `max_retries:`/`retry_backoff:` (transient 5xx/timeouts; typed
`HTTPError` on non-2xx), `max_concurrency:` (semaphore — bound a capacity-limited provider), `tts_async:`
(poll a job-based TTS endpoint). Key only from `ENV["OPENAI_API_KEY"]`. `InMemory` adapter scripts
`complete`/`speak`/`transcribe` for network-free deterministic tests.

### Harness & Conversation (`shaolin-harness`)
A harness is **a state machine over LLM steps**, event-sourced per run, with two modes:

**Autonomous** (`Shaolin::Harness`) — input fixed at start, runs gate→gate to a terminal:
```ruby
class Triage < Shaolin::Harness
  llm model: "gpt-4.1"
  gate :classify, entry: true do
    prompt { |run| "Classify: #{run.input[:text]}" }
    tools  lookup: LookupAccount                 # tools = commands on the bus
    response_format { { type: "json_schema", json_schema: {...} } }   # structured verdict (out.data)
    params max_tokens: 4096
    on_result { |out, run| run.transition_to(out.data[:verdict] == "x" ? :a : :b) }
  end
  gate :done, terminal: true do on_result { |out, run| run.complete(answer: out.text) } end
end
```
Drive: `Runner#run_to_completion(input:)` (sync) or `start`+`advance(id)` (durable); worker-driven via
`Harness.register_durable_provider!` + `shaolin worker`.

**Conversational** (`Shaolin::Conversation`) — a human message per turn, rests at an `await` gate, never
terminal (chatbots/companions):
```ruby
class Companion < Shaolin::Conversation
  stages :onboarding, :free, :offer, :subscriber       # strict, queryable funnel
  edges  onboarding: :free, free: :offer, offer: :subscriber
  window 12; context { |run| "Persona. stage=#{run.stage}" }
  gate :safety, entry: true, to: %i[reply refuse] do
    response_format { {...} }
    on_result { |out, run| run.transition_to(out.data[:verdict] == "unsafe" ? :refuse : :reply) }
  end
  gate :reply, to: %i[await] do            # no prompt → uses context + history
    tools record_offer: RecordOffer
    on_result { |out, run| run.advance_to(:offer) if out.tool_used?(:record_offer); run.transition_to(:await) }
  end
  gate :refuse, reply: "I can't help with that.", to: %i[await]   # canned: fixed text, NO LLM call (#3)
  gate :await, await: true
  on_turn { |reply, run| }                 # deterministic per-turn updates
end

s = Companion.session(id: user_id)         # llm/repo/command_bus default from the kernel (#15)
s.receive("hi")                            # => reply;  s.stage / s.awaiting? / s.history
s.receive([{type:"text",text:"?"},{type:"image_url",image_url:{url:"..."}}])  # multimodal (#11)
s.tag(geo: "DE", variant: "tripwire")      # app dims → conversations_read
```
**Read-side (#5):** `Shaolin::Conversation.register_read_model!` projects `conversations_read`
(session_id, harness, stage, turn_count, last_turn_at, tags jsonb). Query cross-user without driving a
session: `Shaolin::Kernel["conversations.read"].query(stage: "offer", tags: { geo: "DE" })`.

### Realtime (`shaolin-llm`, `Shaolin::LLM::Realtime`)
Provider-agnostic substrate: normalized session events, PCM16/base64 `Audio`, `Session`/`Client` port,
`InMemory` (scriptable) + `OpenAI` (Realtime WS, inject a transport) adapters. Build voice/tool flows on
any backend.

---

## 8. Cross-cutting (`shaolin-core`)

| Thing | Use |
|---|---|
| `Shaolin::Kernel[key]` | shared infra registry (framework-internal; app code uses `import`) |
| `import("mod.key")` | validated cross-module access (mix in `Shaolin::Imports`) |
| `Shaolin::Context[:k]` | fiber-local request bag (set in middleware/auth, read in action; cleared per request) |
| `Shaolin::Tenant.with(id){}` / `.current` | fiber-local tenant carrier |
| `Shaolin::Log` | unified leveled JSON logger; `Log.with(run_id:){}`; firehose via `SHAOLIN_LOG_EVERYTHING=1` |
| `Shaolin::Health.register(name){}` | readiness checks → `/readyz` |
| `Shaolin::Id.generate` / `.deterministic(*keys)` | random / stable v5-style UUID (idempotent ingest) |
| `Shaolin::Keys.deep_symbolize` | symbol keys at the jsonb edge |
| `Shaolin::Cache` / `Shaolin::Store` | ports (Memory + Redis impls) |
| `Shaolin::CircuitBreaker.new(threshold:, reset_timeout:)` | wrap outbound calls (#25) |

---

## 9. HTTP in production & reliability under load

The **walls** (from the production-readiness pass). All HTTP responses carry `x-request-id`; an
`ErrorBoundary` turns any exception into the JSON error contract (prod hides the message); request bodies
capped at `SHAOLIN_MAX_BODY_BYTES` (1 MiB → 413).

- **Admission control (#20):** `SHAOLIN_WEB_CONCURRENCY` ≈ `DB_POOL` bounds in-flight requests; past it →
  503 `overloaded` (load-shed, don't queue behind a saturated pool). Off by default — **set it in prod.**
- **Request timeout (#21):** `SHAOLIN_REQUEST_TIMEOUT` (Falcon) aborts a slow handler, freeing its fiber +
  DB connection (a cooperative Async timeout → 503).
- **Rate limit (#25):** `Shaolin::HTTP::RateLimit` middleware (Redis/Memory-backed), per-IP or custom key.
- **Circuit breaker (#25):** `Shaolin::CircuitBreaker` around RabbitMQ/Redis/HTTP outbound.
- **Metrics (#24):** `/metrics` (Prometheus) — `shaolin_db_pool{state}` (size/busy/idle/waiting),
  `shaolin_http_in_flight`/`_concurrency_max`, `shaolin_outbox_jobs{status}`,
  `shaolin_outbox_oldest_pending_seconds` (worker lag). **These are the signals that predict the cliff** —
  alert on pool `busy`≈`size` + `waiting`>0 and on outbox lag; size the concurrency cap from them.
- **Probes:** `/healthz` (liveness), `/readyz` (runs Health checks → 503 if a dep is down).
- **Server boot** logs a `server.started` banner (url/adapter/env/pool/concurrency/timeout) (#19).

**Sizing best practice:** pick `DB_POOL` ≥ peak concurrent DB-touching requests on the instance; set
`SHAOLIN_WEB_CONCURRENCY` a little above `DB_POOL`; set `SHAOLIN_REQUEST_TIMEOUT` to your p99 budget.
**Scaling model:** one Falcon reactor per container, scale by replicas (Cloud Run / Knative); a worker
runs in its own process/replica.

---

## 10. Testing (best practice)

- **Deterministic by construction:** `Shaolin::LLM::InMemory` (scripted completions/audio), `Cache::Memory`
  / `Store::Memory`, `Messaging::InMemoryPublisher`, harness/conversation on InMemory — no network/keys.
- **Integration:** `Shaolin::Testing.install(config, only: :integration)` truncates between examples.
  Generated apps get a `spec_helper` with an idempotent `boot_app!` (set `SHAOLIN_SKIP_BOOT` for unit specs).
- **Aggregate unit tests** need no DB (pure event sourcing); request specs use rack-test.
- Run `bundle exec rspec`. Verify HTTP with `shaolin server` + curl.

---

## 11. Deploy

`shaolin new` emits a `Dockerfile` (ruby:4.0-slim) + `deploy/service.yaml` (Cloud Run / Knative). HTTP =
Cloud Run service; worker/scheduler = separate deployments. Migrations are a release step (`shaolin migrate`),
not on every pod boot.

---

## 12. Environment variables

| Var | Default | Purpose |
|---|---|---|
| `SHAOLIN_ENV` | development | `production` flips auto-schema/migrate/swagger off |
| `DB_NAME`/`DB_USER`/`DB_HOST`/`DB_PORT` | — | Postgres connection |
| `DB_POOL` | 5 | AR connection pool — **size to concurrency** |
| `DB_CHECKOUT_TIMEOUT` / `DB_REAPING_FREQUENCY` | 5 / 60 | pool wait / leaked-conn reaping |
| `HOST` / `PORT` | 0.0.0.0 / 8080 | bind |
| `SHAOLIN_SERVER` | falcon | `puma` to switch |
| `SHAOLIN_GRACEFUL_TIMEOUT` | 10 | shutdown drain window |
| `SHAOLIN_REQUEST_TIMEOUT` | off | per-request deadline (Falcon) → 503 |
| `SHAOLIN_WEB_CONCURRENCY` | off | in-flight cap → 503 load-shed; set ≈ DB_POOL |
| `SHAOLIN_MAX_BODY_BYTES` | 1 MiB | request body cap → 413 |
| `WORKER_CONCURRENCY` / `WORKER_BATCH` / `WORKER_TX_PER_JOB` | 1 / 20 / off | worker threads / batch / per-job tx |
| `SHAOLIN_LOG` / `SHAOLIN_LOG_LEVEL` / `SHAOLIN_LOG_EVERYTHING` | — | logging (`off` silences; firehose) |
| `SHAOLIN_LINT_STRICT` | off | fail lint on outside-module findings |
| `REDIS_URL` / `RABBITMQ_URL` | — | broker/store connections |
| `OPENAI_API_KEY` / `OPENAI_MODEL` | — | LLM (key never hardcoded) |

---

## 13. Best practices (consolidated)

- **Prefer CRUD; opt into `--es`** only when you need history/audit/replay — ES is ~ a dozen files of
  ceremony per entity.
- **Isolation is sacred.** Cross-module only via `import`/topics. Don't `Kernel[...]` from app code; don't
  `mkdir app/telegram` god-orchestrators (lint `--strict` will catch it). Orchestration lives in a module.
- **Reactors & async projections must be idempotent** (at-least-once). Read-model `project` is an upsert —
  set absolute state, never `+= 1` in a way that breaks on replay.
- **Sync projection = read-your-write + atomic but adds write latency.** Move heavy/slow ones to `async`.
- **Tools = commands.** In harnesses/conversations, model "actions" are commands on the bus — structured,
  testable, auditable. Don't parse the reply text.
- **For reasoning models:** set `read_timeout` generously, `default_params: { max_tokens: ... }` so a
  `<think>` reply isn't truncated, check `completion.truncated?` to retry on `length`.
- **Production checklist:** set `DB_POOL` to concurrency, `SHAOLIN_WEB_CONCURRENCY` ≈ pool,
  `SHAOLIN_REQUEST_TIMEOUT`, scrape `/metrics`, alert on pool saturation + outbox lag, run `shaolin migrate`
  as a release step, run worker + scheduler as separate processes.
- **Test with the InMemory adapters** — the whole stack has deterministic doubles; no network in unit tests.

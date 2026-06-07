# Best practices

> The opinionated "how to use shaolin well" page. Every API below is grounded in the code; signatures
> show the real keyword args + defaults. For the layer-by-layer reference see the sibling guide pages
> ([`cqrs.md`](cqrs.md), [`jobs.md`](jobs.md), [`http.md`](http.md), [`modules.md`](modules.md), …) and the
> top-level [`../GUIDE.md`](../GUIDE.md). This page is the synthesis: the decisions you make once per
> entity / per service that the framework can't make for you.

shaolin gives you walls (lint isolation, atomic outbox, admission control) and deterministic doubles. The
discipline is in *opting into* them. The recurring theme: **set absolute state, react idempotently, isolate
by topic, and size the pools to your concurrency.**

---

## 1. CRUD vs `--es` — pick the cheapest model that fits

The generator default is **CRUD** (`shaolin g module <name>`); event sourcing is **opt-in** (`--es`).
This reversed in the changelog ("Generator default changed: CRUD, not event-sourcing") precisely because
ES is ~11 files of ceremony per entity and the path of least resistance shouldn't push you there.

| | `shaolin g module orders` (CRUD) | `shaolin g module orders --es` |
|---|---|---|
| Files | `order.rb` (AR model) · `dto/` · `controllers/` · `db/migrate/` · `CONTRACT.md` | + `commands/` · `events/` · aggregate · `command_handlers/` · `projections/` · `read_models/` · `queries/` |
| Source of truth | the row | the event stream (rebuildable) |
| Write path | `Order.create!` | command → handler → aggregate `apply` → event → projection |
| Adds a reactor? | no | `--es --reactor` (a `Shaolin::Jobs::Reactor`) |

**Choose CRUD when** the data is CRUD-shaped: you need the current state, not its history; no audit/replay;
no async fan-out off domain events. **Choose `--es` when** you need history/audit, time-travel/replay, an
append-only write path, multiple read models off one event, or reactors/integration events. `--reactor`
*requires* `--es` (a reactor reacts to a domain event). When unsure, start CRUD — you can grow a module
into ES later; you rarely regret *not* having written the ceremony up front.

```bash
shaolin g module invoices                  # CRUD — model + DTO + controller + migration
shaolin g module orders --es               # full CQRS/ES
shaolin g module orders --es --reactor     # + an async reactor
shaolin g field orders total:integer       # add a field (migration + edit checklist)
```

`g field` deliberately does **not** auto-rewrite Ruby — it writes the `add_column` migration and prints the
checklist (command, event, DTO, aggregate, projection, read-model) you must edit together for an ES module.

---

## 2. Isolation discipline — topics, not classes; `import`, not `Kernel`

A module is a folder under `app/modules/<name>/` with a `module.rb` manifest. Isolation is **enforced** by
`shaolin lint`. The two cardinal rules:

**(a) Cross-module access goes through `import("mod.key")`, never `Shaolin::Kernel[...]`.**
`Shaolin::Kernel[key]` is framework-internal infra (`cqrs.command_bus`, `jobs.outbox`, …). App code mixes in
`Shaolin::Imports` (controllers, command/query handlers, and `Shaolin::Jobs::Reactor` already do) and calls
`import`, which resolves through *your module's declared* `imports` — a clear error for an undeclared key,
and `shaolin lint` flags undeclared `import`s **statically** (`undeclared-import`).

```ruby
# module.rb manifest
Shaolin.module("notifications") do
  imports "billing.invoice_reader"           # another module's exported component (validated)
  imports events: ["orders.order_placed"]    # subscribe to another module's event BY TOPIC
  events_published "notifications.sent"        # what we emit cross-module
end

# inside a handler / reactor (already includes Shaolin::Imports)
import("billing.invoice_reader").total_for(id)   # lint-checked; NOT Kernel["..."]
```

**(b) React to another module's event by its dotted topic string, never its event class.**

```ruby
class WelcomeMailer < Shaolin::Jobs::Reactor
  on(Things::Events::UserRegistered) { |e| import("mail.sender").deliver(to: e.data[:email]) }  # OWN module: class
  on("billing.invoice_paid")        { |e| Metrics.bump(e.data[:amount]) }                        # ANOTHER module: topic
end
```

The topic must be in the manifest (`imports events: [...]`); at wire time the `:jobs` provider resolves it
to the event class (`"billing.invoice_paid" → Billing::Events::InvoicePaid`) and binds the block. A missing
class raises loudly at boot. No reference to the other module's constant → `lint` and `graph` stay clean.

**(c) `shaolin lint` reaches *outside* `app/modules/**` too (#17).** It scans everything except
`config/`, `bin/`, `spec/`, `test/`, vendor, and the modules dir, flagging `kernel-internal-access`
(reading `Shaolin::Kernel[...]`) and `outside-module-reference` (touching another module's namespace).
These are **warnings by default (exit 0)**; `--strict` / `SHAOLIN_LINT_STRICT=1` promotes them to CI
failures. **Best practice:** put orchestration *in a module*, not a loose `app/telegram/` god-dir — then
turn on `--strict`.

```bash
shaolin lint            # warnings, exit 0
shaolin lint --strict   # fail CI on outside-module reach-ins   (== SHAOLIN_LINT_STRICT=1)
shaolin graph           # the dependency graph the rules enforce
```

---

## 3. Idempotent projections & reactors — set absolute state

Everything off the event stream is **at-least-once** and **replayable**. The single rule that makes both
safe: **write absolute state, never relative increments.**

`Shaolin::AR::ReadModel.project(id:)` is the upsert primitive — `find_or_initialize_by(pk => id)`, yield,
`save!`:

```ruby
class PostRecord < Shaolin::AR::ReadModel
  self.table_name = "posts_read"
end

class PostsProjection < Shaolin::CQRS::Projection
  on(Events::PostViewed) do |e|
    PostRecord.project(id: e.data[:id]) do |r|
      r.views = e.data[:total_views]   # GOOD: absolute — replay-safe
      # r.views += 1                    # BAD: breaks on replay / re-delivery
    end
  end
end
```

A reactor is an async **side effect** (email, publish, outbound HTTP). Its outbox enqueue is atomic with the
event, but the side effect runs later in `shaolin worker` and can be retried — so it **must be idempotent**:

```ruby
class ChargeCard < Shaolin::Jobs::Reactor
  on(Events::OrderPlaced) do |e|
    # idempotency key derived from the event so a retry is a no-op, not a double charge
    payments.charge(idempotency_key: e.data[:order_id], amount: e.data[:total])
  end
end
```

`Shaolin::Id.deterministic(*keys)` gives a stable v5-style UUID from business keys for idempotent ingest
(`Shaolin::Id.generate` for random). Use it as a natural dedupe key when the event itself doesn't carry one.

The enqueue side is **already** idempotent for you: the outbox uses a unique `(reactor, event_id)` index +
`INSERT ... ON CONFLICT DO NOTHING`, so re-publishing an event never duplicates a job (and never aborts the
append tx). `mark_failed` retries with `DEFAULT_BACKOFF = [1, 10, 60, 600, 3600]`s, dead-lettering after
`max_attempts` (default `5`, = backoff length).

---

## 4. Sync vs async projections — read-your-write vs write latency

A `Shaolin::CQRS::Projection` is **sync by default**: it runs inside the command's append transaction
(read-your-write + atomic with the event), at the cost of added write latency and lock-hold time. Opt a
heavy/slow one out with the `async` macro:

```ruby
class HeavyProjection < Shaolin::CQRS::Projection
  async                                   # self.async => true ; queried with async?
  on(Events::ThingHappened) { |e| ReadModels::Rollup.project(id: e.data[:id]) { |r| ... } }
end
```

| | sync (default) | `async` (#22) |
|---|---|---|
| Runs | in the append tx | off the tx, driven by `shaolin worker` via the outbox |
| Consistency | read-your-write | eventually consistent |
| Cost | write latency + lock hold | requires `:jobs` provider + a running worker |
| Atomicity | commits with the event | at-least-once (idempotent upsert keeps it safe) |

The `:cqrs` provider skips `async?` projections from its synchronous subscription; the `:jobs` provider
enqueues them on their `subscribed_events` (the `reactor` column holds the projection class name). **Rule:**
keep projections you read back in the same request sync; move heavy denormalizations / rollups / things you
don't read-your-write to `async`. Don't make a projection async without a worker running — the read model
will never update.

`unit_of_work` (in the command handler) wraps **append + sync projections + reactor outbox-enqueue in one
transaction** — the atomic outbox. You no longer write `ActiveRecord::Base.transaction` yourself:

```ruby
class CreatePostHandler < Shaolin::CQRS::CommandHandler
  handles CreatePost
  def call(cmd)
    aggregate_repository.unit_of_work(Post.new(cmd.id)) { |p| p.create(title: cmd.title) }
  end
end
```

Rebuild is resumable: `shaolin projections rebuild [name]` /
`ProjectionRunner.rebuild(event_store, projection, after:)` reads in bounded pages and returns the
last-processed id, so a multi-million-event rebuild can checkpoint/restart. Independent projections rebuild
in parallel (each idempotent).

---

## 5. Tools = commands — never parse the reply text

In harnesses and conversations, a model's **actions** are commands on the command bus. A gate declares
`tools name: CommandClass`; when the model calls that tool, the framework dispatches the command. State
changes ride **tools + `on_result`/`on_turn`**, not free-text parsing — structured, testable, auditable,
replayable.

```ruby
class Triage < Shaolin::Harness
  llm model: "gpt-4.1"
  gate :classify, entry: true do
    prompt { |run| "Classify: #{run.input[:text]}" }
    tools lookup: LookupAccount                          # name the model sees => Command on the bus
    response_format { { type: "json_schema", json_schema: {} } }  # typed verdict on out.data
    params max_tokens: 4096
    on_result { |out, run| run.transition_to(out.tool_used?(:lookup) ? :respond : :reject) }
  end
  gate :respond, terminal: true do
    on_result { |out, run| run.complete(answer: out.text) }
  end
end
```

For decisions, prefer a **structured verdict** (`response_format` → `out.data`, symbol keys) over a
pseudo-tool or string-matching the reply. For refusals/nudges/scripted onboarding use a **canned gate**
(`reply:`) — fixed text, **no LLM call** (zero tokens/latency, deterministic); tools/transitions still run.

`Completion` (verify these in `on_result`):

| Member | Returns | Use |
|---|---|---|
| `text` | String | the clean user-facing reply |
| `reasoning` / `reasoning?` | String / Bool | chain-of-thought (separate field or lifted `<think>`) |
| `tool_calls` / `tool_calls?` | `[{name:, arguments:{}}]` / Bool | what the model invoked |
| `tool_used?(name)` | Bool | did it call this tool? |
| `data` / `data?` | Hash (symbol keys) / Bool | parsed structured output (nil unless `response_format`) |
| `finish_reason` | String | `"stop"`/`"length"`/`"tool_calls"`/… |
| `truncated?` | Bool | `finish_reason == "length"` — retry with a higher `max_tokens` |
| `usage` | Hash | token counts |

---

## 6. Reasoning-model settings — don't lose a slow reply

The OpenAI adapter's defaults are tuned for reasoning models. Full signature:

```ruby
Shaolin::LLM::OpenAI.new(
  api_key: ENV["OPENAI_API_KEY"], model: "gpt-4.1",
  base: "https://api.openai.com/v1", transport: nil, reasoning_tag: nil,
  open_timeout: 15, read_timeout: 600, max_retries: 2, retry_backoff: [0.5, 2.0],
  default_params: {}, max_concurrency: nil, tts_async: nil)
```

| kwarg | Default | Gotcha / purpose |
|---|---|---|
| `read_timeout:` | **600** | Net::HTTP's 60s default *dropped* single replies from slow reasoning models (`Net::ReadTimeout`) — 600s fixes it out of the box; tune per deployment. |
| `open_timeout:` | `15` | connect timeout. |
| `default_params:` | `{}` | per-call sampling defaults, e.g. `{ max_tokens: 4096 }`, so a `<think>` reply isn't truncated by the server default. A per-call `params:` overrides. |
| `reasoning_tag:` | `nil` | opt-in: lift an inline `<think>…</think>` block into `Completion#reasoning`, leaving `text` clean (Qwen-style). Off by default so other providers are unaffected. |
| `max_retries:` | `2` (→ up to 3 attempts) | retries **transient only** — 5xx, timeouts (`Net::OpenTimeout`/`ReadTimeout`), dropped sockets. **4xx never retries.** `0` disables. |
| `retry_backoff:` | `[0.5, 2.0]` | waits between retry attempts. |
| `max_concurrency:` | `nil` | semaphore bounding in-flight calls against a capacity-limited provider; retries happen *inside* the held permit so a retry can't oversubscribe the cap. |
| `tts_async:` | `nil` | `{ result_path:, done:, poll_interval:, max_wait: }` for a job-based TTS endpoint (submit → poll → bytes). |

The API key comes **only** from `ENV["OPENAI_API_KEY"]` — never hardcode it. Non-2xx raises a typed
`Shaolin::LLM::HTTPError` (`status`, truncated `body`, `server_error?`) so a gateway's 502/503 HTML page
doesn't crash a turn on a JSON parse.

```ruby
client = Shaolin::Kernel["llm.client"]            # registered by the :llm provider
c = client.complete(messages: [{ role: "user", content: "explain" }],
                    tools: [], response_format: nil, params: { max_tokens: 4096 })
retry_with_more = c.truncated?                     # reasoning model spent its budget inside <think>
c.reasoning if c.reasoning?
```

**Best practice for reasoning models:** generous `read_timeout`, set `default_params: { max_tokens: ... }`,
and check `completion.truncated?` to retry on `"length"` instead of treating a budget-cut reply as a stop.

Audio shares the same timeout/retry/HTTPError/concurrency layer:
`speak(text, voice: "alloy", format: "mp3", model: "tts-1")` (TTS → bytes),
`transcribe(audio_bytes, language: nil, model: "whisper-1", filename: "audio.wav", content_type: "audio/wav")`.

---

## 7. Admission control, request timeout, pool sizing — the load walls

Under load the failure mode is the **connection-pool cliff**: more in-flight requests than DB connections →
everything queues on `DB_CHECKOUT_TIMEOUT` and the instance falls over. The framework gives you three walls;
**all three are off by default — turn them on in prod.**

| Wall | Knob | Default | Behavior |
|---|---|---|---|
| Admission control (#20) | `SHAOLIN_WEB_CONCURRENCY` (or `HTTP.register_provider!(max_concurrency:)`) | off | semaphore caps in-flight requests; past the cap → **503 `overloaded`** immediately (load-shed, don't queue). |
| Request timeout (#21) | `SHAOLIN_REQUEST_TIMEOUT` (seconds, Falcon only) | off | cooperative `Async` timeout aborts a slow handler, freeing its fiber + DB connection → **503 `timeout`**. Inert under Puma. |
| Body cap | `SHAOLIN_MAX_BODY_BYTES` | 1 MiB | oversize body → **413** before buffering. |

```ruby
Shaolin::HTTP.register_provider!(middleware: [], swagger: false, auth: {}, max_concurrency: nil)
# max_concurrency falls back to ENV["SHAOLIN_WEB_CONCURRENCY"] when nil
```

**Sizing recipe** (the whole chain must line up):

- `DB_POOL` (default `5`) ≥ peak concurrent **DB-touching** requests on the instance.
- `SHAOLIN_WEB_CONCURRENCY` a little **above** `DB_POOL` (shed before you exhaust the pool).
- `SHAOLIN_REQUEST_TIMEOUT` ≈ your p99 latency budget.
- For the worker: `DB_POOL ≥ WORKER_CONCURRENCY` (the CLI warns if `WORKER_CONCURRENCY` exceeds the pool).

**Find the numbers from `/metrics`** (Prometheus, #24) — these signals predict the cliff:

| Metric | Alert when |
|---|---|
| `shaolin_db_pool{state}` (size/busy/idle/waiting) | `busy` ≈ `size` **and** `waiting` > 0 |
| `shaolin_http_in_flight` / `shaolin_http_concurrency_max` | in_flight near max (you're shedding) |
| `shaolin_outbox_oldest_pending_seconds` | worker lag growing (`Outbox#oldest_pending_age`) |
| `shaolin_outbox_jobs{status}` | `dead` > 0, or `pending` climbing |

**Scaling model:** one Falcon reactor per container; scale by **replicas** (Cloud Run / Knative). The worker
and scheduler each run in their **own** process/replica. The scheduler self-elects a single leader across
replicas via a Postgres advisory lock, so running N is safe.

Worker tuning (`shaolin worker`): `WORKER_BATCH` (20) jobs per drain, `WORKER_CONCURRENCY` (1) threads, and
**`WORKER_TX_PER_JOB=1`** for **IO-bound** reactors (outbound HTTP) — each job commits in its own short tx so
a slow call holds a row lock for one job, not the whole batch. Run the **harness durable worker and
async-projection worker with `WORKER_TX_PER_JOB=1`** (each gate's LLM call is IO-bound).

Outbound resilience: wrap RabbitMQ/Redis/HTTP calls in `Shaolin::CircuitBreaker.new(threshold: 5,
reset_timeout: 30)` — `breaker.call { outbound }` fast-fails (`OpenError`) during a brownout instead of
piling up doomed calls. `Shaolin::RabbitMQ::Publisher.new(breaker:)` wires one in. Rate-limit at the edge
with `Shaolin::HTTP::RateLimit` (any `Shaolin::Store` backend; per-IP or a custom `key:` lambda).

---

## 8. Testing with InMemory — deterministic, no network, no keys

The whole stack ships deterministic doubles. Build unit/integration tests with **no network and no keys**.

| Real | InMemory double |
|---|---|
| `Shaolin::LLM::OpenAI` | `Shaolin::LLM::InMemory.new(*responses, speak: [], transcribe: [])` |
| `Shaolin::Cache::Memory` | (already in-memory; swap for `Redis::Cache`) |
| `Shaolin::Store::Memory` | (already in-memory; swap for `Redis::Store`) |
| `Shaolin::RabbitMQ::Publisher` | `Shaolin::Messaging::InMemoryPublisher` |
| `Shaolin::LLM::Realtime::OpenAI` | `Shaolin::LLM::Realtime::InMemory` |

`InMemory` hands back scripted `Completion`s in order and **records every call** (`#calls`) so you can assert
on the prompt/tools/`params`/`response_format` sent — perfect for deterministic harness/conversation replay:

```ruby
llm = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(text: "billing", reasoning: "mentions an invoice", data: { verdict: "billing" }),
  { text: "done" }   # a bare hash is splatted into Completion.new
)
session = MyConversation.session(id: "u1", llm: llm)   # repo/command_bus also injectable
session.receive("hi")
llm.calls.last[:tools]    # assert what the gate offered
```

**Integration DB isolation** — truncate read models + event store + outbox before each tagged example:

```ruby
# spec_helper.rb
Shaolin::Testing.install(rspec_config, only: :integration)   # only: nil = every example
```

Generated apps get a `spec_helper` with an idempotent `boot_app!` (set `SHAOLIN_SKIP_BOOT` for pure unit
specs). **Aggregate unit tests need no DB** (pure event sourcing — apply events, assert state). Request specs
use rack-test. Run `bundle exec rspec`; smoke HTTP with `shaolin server` + curl.

---

## 9. The consolidated checklist

- **Default to CRUD;** opt into `--es` only for history/audit/replay/fan-out. `--reactor` needs `--es`.
- **Isolation is sacred:** cross-module only via `import("mod.key")` + topic strings; never `Kernel[...]`
  from app code; orchestration lives in a module. Run `shaolin lint --strict` in CI.
- **Idempotent everywhere off the stream:** projections/reactors set **absolute state**; enqueue dedupe is
  free (`(reactor, event_id)` unique). Use `Shaolin::Id.deterministic` for ingest keys.
- **Sync = read-your-write + atomic but adds write latency;** move heavy read models to `async` (+ worker).
- **Tools = commands.** Decisions via `response_format`/`out.data`; refusals via canned `reply:` gates.
- **Reasoning models:** generous `read_timeout`, `default_params: { max_tokens: ... }`, retry on `truncated?`.
- **Set the load walls in prod:** `DB_POOL` to concurrency, `SHAOLIN_WEB_CONCURRENCY` ≈ pool,
  `SHAOLIN_REQUEST_TIMEOUT` ≈ p99; scrape `/metrics`, alert on pool saturation + outbox lag.
- **Run `shaolin migrate` as a release step;** run worker + scheduler as separate processes
  (`WORKER_TX_PER_JOB=1` for IO-bound / harness / async-projection workers).
- **Test on the InMemory doubles** — the whole stack has deterministic, network-free stand-ins.

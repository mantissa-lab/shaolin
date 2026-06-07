# Testing

shaolin is built to be tested **fast and deterministically**. The core idea: every external dependency
(LLM, cache, KV store, message broker) has a port (a Ruby module) and an in-process **InMemory double**
that satisfies it without a network, keys, or a server. DB-less unit specs run against pure aggregates;
`:integration` request/harness specs boot the app once and isolate the DB between examples by truncation.

| Layer | What you test | Needs a DB? | Tools |
| --- | --- | --- | --- |
| Aggregate unit | command → events on the aggregate | no | plain RSpec |
| Request | HTTP → command → event → projection → query | yes (`:integration`) | `Rack::Test` + `boot_app!` |
| Harness / Conversation | gate state machine, replay | yes (event store) | `Shaolin::LLM::InMemory` |
| Doubles | cache/store/publisher behavior | no | `Cache::Memory`, `Store::Memory`, `InMemoryPublisher` |

---

## 1. The InMemory doubles

### `Shaolin::LLM::InMemory`

Scripted in-process LLM — no network, no keys. Hand it `Completion`s (or hashes) to return **in order**;
it records every call on `#calls` so specs can assert on the prompt, tools, `response_format`, and `params`
that were sent. Including `reasoning:` on a scripted `Completion` lets harness tests assert on the persisted
reasoning trace.

```ruby
def initialize(*responses, speak: [], transcribe: [])
def complete(messages:, tools: [], model: nil, response_format: nil, params: {})  # → Completion
def speak(text, voice: nil, format: nil, model: nil)                              # → next scripted speak
def transcribe(audio, language: nil, model: nil)                                  # → next scripted text
attr_reader :calls
```

- `responses` are splatted **and flattened**, so `InMemory.new(c1, c2)` and `InMemory.new([c1, c2])` are equivalent.
- A `Completion` is returned as-is; a `Hash` is turned into `Completion.new(**hash)`.
- **Gotcha:** running out of scripted responses raises `"InMemory LLM: no scripted response left (call #N)"`.
  `speak`/`transcribe` raise their own "no scripted … left" if their arrays are exhausted.
- `#calls` entries are tagged: chat calls store `{ messages:, tools:, model:, response_format:, params: }`;
  audio calls store `{ audio: :speak, … }` / `{ audio: :transcribe, … }`.

```ruby
llm = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(text: "billing", reasoning: "mentions an invoice"),
  { text: "done" }
)
out = llm.complete(messages: [{ role: "user", content: "hi" }], model: "stub")
out.text                       # => "billing"
out.reasoning                  # => "mentions an invoice"
llm.calls.last[:model]         # => "stub"
llm.complete(messages: []).text  # => "done"
```

#### `Shaolin::LLM::Completion`

The transport-agnostic result every adapter returns. Scripted by `InMemory`, asserted by harness specs.

```ruby
def initialize(text: nil, reasoning: nil, tool_calls: [], usage: {}, data: nil, finish_reason: nil)
attr_reader :text, :reasoning, :tool_calls, :usage, :data, :finish_reason
def tool_calls?        # any tool requested?
def tool_used?(name)   # was a tool with this name requested? (string/symbol-insensitive)
def reasoning?         # non-empty reasoning trace?
def data?              # structured output present?
def truncated?         # finish_reason == "length" (reply cut at the token budget)
def to_h
```

- `tool_calls` is an array of `{ name:, arguments: {} }`.
- `data` is the parsed structured output (a Hash with **symbol keys**) when a `response_format:` was requested.

```ruby
c = Shaolin::LLM::Completion.new(tool_calls: [{ name: "lookup", arguments: { id: "a1" } }])
c.tool_calls?         # => true
c.tool_used?(:lookup) # => true
```

#### Wiring it as the `:llm` provider

`Shaolin::LLM.register_provider!(client:)` registers the chat client as `llm.client` in the kernel. Pass
`InMemory` in tests; the default (`client: nil`) builds the OpenAI adapter from `OPENAI_API_KEY` / `OPENAI_MODEL`.

```ruby
Shaolin::LLM.register_provider!(client: Shaolin::LLM::InMemory.new(c1, c2))
```

### `Shaolin::Cache::Memory`

Process-local cache implementing the `Shaolin::Cache` port, with optional per-key TTL (lazy expiry on read).
`now:` is injectable so TTL is testable without sleeping. Swapping in `Shaolin::Redis::Cache` is a one-line
provider change.

```ruby
def read(key, now: Time.now)
def write(key, value, ttl: nil)            # returns value
def delete(key)
def exist?(key, now: Time.now)             # !read(...).nil?  (from the port)
def clear
def fetch(key, ttl: nil, now: Time.now)    # cache-aside; computes via block on miss (from the port)
```

- TTL is in **seconds**; `write` stamps `expires_at = Time.now + ttl`. A `read` at/after `expires_at`
  deletes the entry and returns `nil`.
- **Gotcha:** `now:` only shifts the *read*-side clock — `write` always uses real `Time.now` for the stamp.
  To exercise expiry, write then `read(key, now: Time.now + ttl + 1)`.

```ruby
cache = Shaolin::Cache::Memory.new
cache.fetch("u:1", ttl: 60) { expensive_lookup }  # computes + stores
cache.read("u:1", now: Time.now + 61)             # => nil (expired)
```

### `Shaolin::Store::Memory`

Process-local KV/hash store implementing the `Shaolin::Store` port. Mirrors `Shaolin::Redis::Store`
semantics: values are **JSON round-tripped**, so reads return symbol keys; counters are native integers.

```ruby
def set(key, value, ttl: nil)        # returns value; ttl no-op in-memory
def get(key)                         # JSON.parse(..., symbolize_names: true) or nil
def delete(key)                      # 1 if deleted, else 0
def exists?(key)                     # checks both kv + hashes
def increment(key, by: 1, ttl: nil)  # native Integer; ttl no-op in-memory
def decrement(key, by: 1)            # increment(key, by: -by)
def hset(key, field, value)          # returns 1
def hget(key, field)                 # parsed value or nil
def hgetall(key)                     # { field_sym => parsed_value }
def keys(pattern = "*")              # glob "*" only (translated to a regex)
```

- **Gotcha:** keys are coerced with `.to_s`, so `set(:a, 1)` and `set("a", 1)` collide.
- **Gotcha:** `ttl:` is a **no-op** in `Memory` (set/increment) — expiry is not simulated. Use Redis for real TTL.
- `keys` supports glob `*` only (`"u:*"`), translated to `\Au:.*\z`; other glob metachars are escaped literally.

```ruby
store = Shaolin::Store::Memory.new
store.set("session:1", { user: 42 })
store.get("session:1")              # => { user: 42 }   (symbol keys)
store.increment("hits", by: 2)      # => 2
store.hset("acct:1", "balance", 100)
store.hgetall("acct:1")             # => { balance: 100 }
store.keys("acct:*")                # => ["acct:1"]
```

### `Shaolin::Messaging::InMemoryPublisher`

In-process implementation of the `Shaolin::Messaging::Publisher` port for monolith/dev/test: it records
what was published on `#published` (the real adapter is `Shaolin::RabbitMQ::Publisher`).

```ruby
def initialize
def publish(integration_event)   # appends to @published, returns the event
attr_reader :published
```

```ruby
pub = Shaolin::Messaging::InMemoryPublisher.new
pub.publish(event)
pub.published          # => [event]
```

---

## 2. DB isolation: `Shaolin::Testing`

DatabaseCleaner-style, opt-in truncation. `clean!` **truncates every app table** — read models, the event
store, AND the jobs outbox/schedules — so integration examples don't accumulate rows across runs (a stale
`pending` outbox job firing in a later example was a real footgun). Only AR's own bookkeeping tables are preserved.

```ruby
PRESERVE = %w[schema_migrations ar_internal_metadata]

def clean!                                   # TRUNCATE ... RESTART IDENTITY CASCADE
def install(rspec_config, only: nil)         # register a before(:each) that cleans
```

- `clean!` is a no-op when there are no app tables (nothing booted yet).
- `install(config, only: :integration)` scopes the hook to a tag so DB-less unit specs stay fast. With
  `only: nil` it cleans before **every** example.
- It runs `TRUNCATE ... RESTART IDENTITY CASCADE` — Postgres-only; resets sequences and cascades FKs.

```ruby
RSpec.configure { |c| Shaolin::Testing.install(c, only: :integration) }
```

---

## 3. Generated `spec_helper`, `boot_app!`, and `SHAOLIN_SKIP_BOOT`

`shaolin new <app>` scaffolds `spec/spec_helper.rb`:

```ruby
# Loads the framework + app code WITHOUT booting (no DB needed for unit specs).
ENV["SHAOLIN_SKIP_BOOT"] ||= "1"

require_relative "../config/boot"
require "rack/test"
require "json"

def boot_app!
  $shaolin_booted ||= MyApp.boot!   # idempotent across spec files
end

require "shaolin/activerecord"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.before(:each, :integration) { boot_app! }
  Shaolin::Testing.install(config, only: :integration)
end
```

| Symbol | Purpose |
| --- | --- |
| `ENV["SHAOLIN_SKIP_BOOT"]` | Set to `"1"` so requiring `config/boot` loads code **without** running `boot!` (no DB for unit specs). `\|\|=` lets callers override. |
| `boot_app!` | Boots the app **once** (memoized in `$shaolin_booted`); idempotent across files. Called from a `before(:each, :integration)`. |
| `:integration` tag | Marks specs that need a booted app + DB. Drives both the `boot_app!` hook and `Shaolin::Testing.install(..., only: :integration)` truncation. |

Untagged examples never boot or touch the DB — they stay fast.

---

## 4. Aggregate unit tests (no DB)

`shaolin generate` produces a pure aggregate spec — no app boot, no database. You instantiate the aggregate,
issue a command, and assert on `unpublished_events`.

```ruby
require "spec_helper"
require_relative "../app/modules/billing/invoice"

RSpec.describe Billing::Invoice do
  it "records InvoiceCreated when created" do
    record = described_class.new("test-id")
    record.create(name: "Example")

    types = record.unpublished_events.to_a.map(&:event_type)
    expect(types).to include("Billing::Events::InvoiceCreated")
  end
end
```

These run with `SHAOLIN_SKIP_BOOT=1` in effect (no `:integration` tag) — milliseconds, no Postgres.

---

## 5. Request specs (rack-test, `:integration`)

Generated request/CRUD specs boot the app and drive the real Rack stack via `Rack::Test::Session` against
`Shaolin::Kernel["http.app"]`. They exercise the full path: HTTP → command → event → projection → query.

```ruby
require "spec_helper"

RSpec.describe "billing requests", :integration do
  before(:all) { boot_app! }

  let(:session) { Rack::Test::Session.new(Shaolin::Kernel["http.app"]) }

  it "creates, reads and lists (command -> event -> projection -> query)" do
    session.post("/billing", JSON.generate(name: "Example"), "CONTENT_TYPE" => "application/json")
    expect(session.last_response.status).to eq(201)

    session.get(session.last_response.headers["location"])
    expect(JSON.parse(session.last_response.body)["name"]).to eq("Example")

    session.get("/billing")
    expect(JSON.parse(session.last_response.body)).to be_an(Array)
  end
end
```

The CRUD template additionally covers `PATCH` (200), `DELETE` (204), and a follow-up `GET` returning 404.
Because the spec is tagged `:integration`, `Shaolin::Testing` truncates the DB before each example, so rows
(and stale pending outbox jobs) never bleed across examples.

---

## 6. Deterministic harness & conversation tests

Harnesses (`Shaolin::Harness`) and conversations (`Shaolin::Conversation`) are event-sourced gate state
machines. Tests stay deterministic by binding `Shaolin::LLM::InMemory` as `llm.client` and scripting one
`Completion` per gate that calls the model (canned `reply:`/`await:` gates make **no** LLM call). State lives
in the event store, so a fresh `Runner`/`session` replays to the same place — that is what makes replay tests possible.

### Booting providers in a spec

Harness/conversation specs reset and start providers by hand (the harness gem's `spec_helper` provides the
`PgTest` Postgres config + `reset_schema!`):

```ruby
Shaolin::Provider.reset!
Shaolin::Kernel.reset!
PgTest.reset_schema!
Shaolin::AR.register_provider!(config: PgTest::CONFIG)
Shaolin::CQRS.register_provider!
Shaolin::LLM.register_provider!(client: llm)   # InMemory
Shaolin::Provider.start_all
Shaolin::Kernel["cqrs.command_bus"].register(LookupAccount, ->(cmd) { "balance:#{cmd.id}" })
```

`PgTest::CONFIG` reads `DB_NAME` (`shaolin_test`), `DB_USER` (`postgres`), `PGPASSWORD`, `DB_HOST` (`/tmp`),
`DB_PORT` (`5433`). The gem's `spec_helper` also sets `ENV["SHAOLIN_LOG"] ||= "off"`.

### Driving a harness — `Shaolin::Harness::Runner`

```ruby
def initialize(harness:, llm:, repo:, command_bus: nil)
def start(input: nil, id: Shaolin::Id.generate)   # appends entry GateEntered, returns id
def advance(id)                                    # one gate: prompt → llm → tool → transition
def run_to_completion(input: nil, id: Shaolin::Id.generate)
def load(id)                                       # reconstruct the Run from the event store
def started?(id)
```

```ruby
llm = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(tool_calls: [{ name: "lookup", arguments: { id: "a1" } }]), # classify
  Shaolin::LLM::Completion.new(text: "Here is your balance.")                              # respond
)
runner = Shaolin::Harness::Runner.new(
  harness: TriageHarness, llm: Shaolin::Kernel["llm.client"],
  repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: Shaolin::Kernel["cqrs.command_bus"]
)
run = runner.run_to_completion(input: { text: "where is my money" })
run.completed?    # => true
run.output        # => { answer: "Here is your balance.", account: "balance:a1" }
run.tool_results  # => [{ name: "lookup", result: "balance:a1" }]
```

**Deterministic replay:** `runner.load(id)` twice yields the same `output` / `current_gate`. **Resume:** a
brand-new `Runner` advancing the same `id` does NOT redo completed gates — assert `llm.calls.size` to prove it.

**Durable/outbox mode:** call `Shaolin::Harness.register_durable_provider!` (after `:active_record`, `:cqrs`,
`:jobs`, `:llm`); each `GateEntered` enqueues one outbox job, and a `Shaolin::Jobs::Worker#run_once` advances
one gate. Assert on `Shaolin::Jobs::OutboxJob.where(status:).count`.

### Conversations — `Shaolin::Conversation`

Human-paced: each `receive` is one turn that runs within-turn gates then rests at an `await:` gate (never terminal).

```ruby
def self.session(id:, llm: nil, repo: nil, command_bus: nil)  # nil args self-resolve from the kernel
# session instance:
def receive(message)   # → assistant reply string; message may be text, structured content, or { text:, images: }
```

```ruby
session = CompanionConvo.session(
  id: Shaolin::Id.generate, llm: Shaolin::Kernel["llm.client"],
  repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: bus
)
session.receive("hello")   # => "Hi there!"
session.awaiting?          # => true  (rests for the next human message)
session.run.terminal?      # => false
session.history            # => [{ role: "user", content: "hello" }, { role: "assistant", content: "Hi there!" }, ...]
session.stage              # current funnel stage, e.g. "free"
session.tag(geo: "DE")     # attach tags (surfaced on the read model)
```

`session(id:)` with no `llm:`/`repo:`/`command_bus:` self-resolves them from the kernel (handy once providers
are started). Build per-turn completions with a tiny helper:

```ruby
def c(text: nil, tool: nil)
  Shaolin::LLM::Completion.new(text: text, tool_calls: tool ? [{ name: tool, arguments: {} }] : [])
end
```

Assert determinism on `llm.calls`: a canned `reply:`/`await:` gate makes no LLM call (`llm.calls.size`), a
gate's `response_format`/`params` flow through verbatim (`llm.calls.last[:response_format]` / `[:params]`),
and multimodal content is persisted and fed to the model unchanged (`llm.calls.last[:messages]`).

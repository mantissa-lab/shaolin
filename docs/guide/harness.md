# Harness & Conversation

`shaolin-harness` (`require "shaolin/harness"`, gem version `0.1.0`) models an LLM
agent as a **gate state machine, event-sourced per run** — durable, auditable,
replayable. You subclass `Shaolin::Harness`, declare **gates** (states) with a
class-level DSL, and drive the machine with a `Runner`. Each gate builds a prompt,
calls the LLM, optionally invokes **tools** (which are plain Commands on the CQRS
command bus), then `on_result` decides the next gate or completes the run. The
whole run is a stream of events in the same Postgres event store as your domain,
so a crash resumes from the last persisted gate.

Two modes share one engine:

- **Autonomous** (`Shaolin::Harness`): runs from an `entry` gate to a `terminal`
  gate (`run_to_completion`).
- **Conversational** (`Shaolin::Conversation`): human-paced; a turn is fed an
  inbound message and the run **rests at an `await` gate** between turns instead
  of terminating. Adds a strict funnel (`stages`/`edges`), a memory `window`, a
  persona `context`, and an opt-in cross-user read model.

```ruby
require "shaolin/harness"
```

---

## Big picture

| Piece | Class / module | Role |
|---|---|---|
| Harness base | `Shaolin::Harness` | Subclass + gate DSL; auto-registers |
| Gate DSL | `Shaolin::Harness::DSL` | `harness_name`, `llm`, `gate`, `describe` |
| Gate | `Shaolin::Harness::Gate` (+ `GateBuilder`) | One state: prompt/tools/on_result |
| Run | `Shaolin::Harness::Run` | Event-sourced aggregate (the state machine) |
| Events | `Shaolin::Harness::Events` | The run's audit stream |
| Runner | `Shaolin::Harness::Runner` | Drives the machine (sync / per-step) |
| Registry | `Shaolin::Harness::Registry` | `harness_name` → subclass (for durable drive) |
| Durable driver | `Shaolin::Harness::DriveReactor` | Advances a run per `GateEntered` via the outbox |
| Conversation | `Shaolin::Conversation` | Human-paced mode + funnel/window/context |
| Session | `Shaolin::Conversation::Session` | Bound handle for one session id |
| Read model | `Shaolin::Conversation::{Schema,ReadRow,Projector,Reader}` | Cross-user `conversations_read` projection |

Tools are commands; an LLM call returns a `Shaolin::LLM::Completion` (`text`,
`reasoning`, `tool_calls`, `usage`, `data`, `finish_reason` — see the LLM guide).
Gate `on_result` blocks receive that completion plus the live `Run`.

---

## 1. Defining a harness — the gate DSL

Subclass `Shaolin::Harness`; the subclass auto-registers (`inherited` → `Registry`).
`Shaolin::Harness extend DSL`, so these are class methods on your subclass.

```ruby
class TriageHarness < Shaolin::Harness
  harness_name "triage"
  llm model: "gpt-4.1"

  gate :classify, entry: true, to: %i[respond reject] do
    prompt { |run| "Classify: #{run.input[:text]}" }
    tools lookup: LookupAccount                       # tool name => Command class
    on_result { |out, run| run.transition_to(out.tool_used?(:lookup) ? :respond : :reject) }
  end

  gate :respond, terminal: true do
    prompt { |run| "Answer using #{run.tool_results.last[:result]}" }
    on_result { |out, run| run.complete(answer: out.text, account: run.tool_results.last[:result]) }
  end

  gate :reject, terminal: true do
    prompt { "n/a" }
    on_result { |_out, run| run.complete(answer: "rejected") }
  end
end
```

### `Shaolin::Harness::DSL` (class methods)

| Method | Signature | Purpose |
|---|---|---|
| `harness_name` | `harness_name(value = nil)` | Get/set the stable name (string). Defaults to the snake_cased class basename, or `"harness"` for anonymous classes. |
| `llm` | `llm(model: nil)` | Get/set the default model id. Returns the stored model. |
| `model` | `model` | Reader for the stored model id. |
| `gate` | `gate(name, entry: false, terminal: false, await: false, reply: nil, to: [], &block)` | Declare one gate; block runs in a `GateBuilder`. |
| `gates` | `gates` | `{ "name" => Gate }`, declaration order preserved. |
| `gate_for` | `gate_for(name)` | Fetch a `Gate` by name; raises `ArgumentError` if absent. |
| `entry_gate` | `entry_gate` | The single gate with `entry: true`; raises if none. |
| `describe` | `describe` | Machine-readable map (name, model, gates with entry/terminal/await/tools/to). |

`gate` keyword args:

| Kwarg | Default | Meaning |
|---|---|---|
| `entry:` | `false` | The start gate. Exactly one per harness. |
| `terminal:` | `false` | A finish state (`complete`/`fail` here). |
| `await:` | `false` | A **resting** state — `advance` is a no-op; only an inbound human message (`receive`) proceeds. Conversational mode. |
| `reply:` | `nil` | **Canned** gate: fixed text, **no LLM call**. String or `->(run){…}`. |
| `to:` | `[]` | DECLARED possible next gates — used only for `describe`/graphing. The real transition is whatever `on_result` calls at runtime. |

> **Gotcha — `to:` is documentation, not enforcement.** It feeds `describe`; the
> runtime transition is decided entirely inside `on_result`. (Funnel `stages`,
> below, *are* enforced.)

### `Shaolin::Harness::GateBuilder` (block DSL inside `gate … do … end`)

| Method | Signature | Purpose |
|---|---|---|
| `prompt` | `prompt(value = nil, &block)` | The gate's prompt. String → one user message; `->(run){…}` may return a string or an array of `{role:, content:}` messages. |
| `reply` | `reply(value = nil, &block)` | Canned reply (no LLM call); string or `->(run){…}`. Same as the `reply:` kwarg. |
| `response_format` | `response_format(value = nil, &block)` | Structured-output spec passed to the LLM; the parsed object arrives on `out.data`. Hash or `->(run){…}`. |
| `params` | `params(value = nil, &block)` | Sampling params merged into the LLM request (override adapter defaults), e.g. `params(max_tokens: 4096)`. Hash or `->(run){…}`. |
| `tools` | `tools(**mapping)` | `tools(lookup: LookupAccount)` — the name the model sees → the Command class dispatched when it calls the tool. Merges across calls. |
| `on_result` | `on_result(&block)` | `\|completion, run\|` — runs inside the step's DB transaction; calls `run.transition_to`/`run.complete`/`run.fail`/`run.advance_to`. |

### `Shaolin::Harness::Gate` (Struct, `keyword_init`)

Fields: `name, entry, terminal, await, prompt, reply, response_format, params,
tools, on_result, transitions`. Helpers:

| Method | Meaning |
|---|---|
| `tool_names` | Keys of the `tools` mapping (symbols). |
| `transition_names` | Declared `to:` gates as strings. |
| `await?` | `!!await` — resting state. |
| `canned?` | `!reply.nil?` — fixed-text gate, no LLM call. |

```ruby
TriageHarness.describe
# => { name: "triage", model: "gpt-4.1",
#      gates: [{ name: "classify", entry: true, terminal: false, await: false,
#                tools: ["lookup"], to: ["respond", "reject"] }, ...] }
```

---

## 2. `Shaolin::Harness::Run` — the event-sourced aggregate

`include Shaolin::CQRS::Aggregate`. One event stream per run; current gate,
status, history, stage and tags are derived by replaying events. You rarely
build a `Run` directly — the `Runner` does, in a `unit_of_work`. Inside an
`on_result` block you call its command methods on the live aggregate.

Statuses: `RUNNING = "running"`, `COMPLETED = "completed"`, `FAILED = "failed"`.

### Command methods (each `apply`s one event)

| Method | Signature | Emits | Use |
|---|---|---|---|
| `start` | `start(harness:, input: nil, stage: nil, edges: nil)` | `RunStarted` | Begin a run (Runner calls this). |
| `enter` | `enter(gate)` | `GateEntered` | Move into a gate (drives the durable loop). |
| `prompted` | `prompted(gate, prompt)` | `Prompted` | Audit the prompt sent. |
| `responded` | `responded(gate, completion)` | `Responded` | Audit the full completion (incl. reasoning/usage). |
| `tool_invoked` | `tool_invoked(gate, name, arguments)` | `ToolInvoked` | Audit a tool call. |
| `tool_returned` | `tool_returned(gate, name, result)` | `ToolReturned` | Audit a tool result (feeds `tool_results`). |
| `transition_to` | `transition_to(gate)` | `Transitioned` + `GateEntered` | **From `on_result`:** record the edge AND enter the next gate. |
| `complete` | `complete(output)` | `Completed` | Finish successfully; `output` is your hash. |
| `fail` | `fail(error)` | `Failed` | Finish in failure. |
| `received` | `received(content)` | `MessageReceived` | Record an inbound human message (start of a turn). `content` is a String or OpenAI-style content array (multimodal). |
| `replied` | `replied(text)` | `Replied` | The turn's user-facing reply (its assistant history entry). |
| `advance_to` | `advance_to(to)` | `StageChanged` | Advance the funnel — **strict** against declared `edges`; no-op if already there; raises `Shaolin::Error` on an undeclared jump. |
| `tag` | `tag(attrs)` | `Tagged` | Stamp app dimensions (geo/variant/segment); no-op on nil/empty. |

> **`transition_to` vs `enter`.** `transition_to` records the edge then enters —
> use it from `on_result`. `enter` only emits `GateEntered` (the Runner uses it
> to seed the entry gate / wake a conversation).

### Query methods (derived state)

| Method | Returns |
|---|---|
| `harness_name`, `input`, `current_gate`, `status`, `output`, `stage` | attr readers |
| `terminal?` / `completed?` / `failed?` | status predicates |
| `responded?(gate)` / `response_for(gate)` | per-gate audit lookup |
| `tool_results` | `[{ name:, result: }, …]` (oldest first) |
| `last_text` | last assistant text (per-gate `Responded` text or a `Replied`) |
| `history` | chat history `[{ role:, content: }]`, oldest first (user `MessageReceived` interleaved with `Replied`) |
| `recent(n = nil)` | last `n` history messages (the memory window), or all if `nil` |
| `tags` | `{ "geo" => "DE", … }` (string keys) |

```ruby
run = Shaolin::Harness::Run.new("conv-1")
run.start(harness: "companion", stage: "onboarding",
          edges: { "onboarding" => ["free"], "free" => ["offer"] })
run.advance_to(:free)               # ok — declared
run.advance_to(:subscriber)         # raises Shaolin::Error: illegal stage transition "free" → "subscriber"
```

> **Gotcha — edges round-trip as strings.** Events may turn symbol keys into
> strings; the aggregate normalizes both `from` and `to` to strings, so compare
> stages as strings (`run.stage == "free"`).

---

## 3. `Shaolin::Harness::Events`

`module Events` — each is a `RubyEventStore::Event` subclass; one stream per run.

| Event | When |
|---|---|
| `RunStarted` | `start` — carries `run_id, harness, input, stage, edges` |
| `GateEntered` | `enter` — `run_id, gate` (the durable drive trigger) |
| `Prompted` | `prompted` — `gate, prompt` |
| `Responded` | `responded` — `gate, text, reasoning, tool_calls, usage, data, finish_reason` |
| `ToolInvoked` / `ToolReturned` | tool call / result — `gate, name, arguments`/`result` |
| `Transitioned` | `transition_to` — `from, to` |
| `Completed` / `Failed` | `complete`/`fail` — `output` / `gate, error` |
| `MessageReceived` | `received` — `run_id, content` (conversational; a turn start) |
| `Replied` | `replied` — `run_id, content` (the turn's reply) |
| `StageChanged` | `advance_to` — `run_id, from, to` (strict funnel) |
| `Tagged` | `tag` — `run_id, tags` (app dimensions) |

---

## 4. `Shaolin::Harness::Runner` — driving the machine

Each `advance` is **one atomic gate step**: build prompt → call LLM → dispatch
tool commands happen **outside** the DB transaction; then a single `unit_of_work`
appends that step's events (`prompted`, `responded`, tools, and the `on_result`
transition/completion) atomically. A crash before commit replays the step
(**at-least-once** on LLM/tool calls — keep tools idempotent); a crash after
resumes at the next gate.

```ruby
def initialize(harness:, llm:, repo:, command_bus: nil)
```

| Kwarg | Default | Meaning |
|---|---|---|
| `harness:` | — | The harness class. |
| `llm:` | — | An LLM client (`Shaolin::Kernel["llm.client"]` or `InMemory`). |
| `repo:` | — | Aggregate repository (`Shaolin::Kernel["cqrs.aggregate_repository"]`). |
| `command_bus:` | `nil` | The CQRS command bus; **required for tools** — without it, tool calls are skipped (`run_tools` returns `[]`). |

### Methods

| Method | Signature | Purpose |
|---|---|---|
| `start` | `start(input: nil, id: Shaolin::Id.generate)` | Append `RunStarted` (with the harness's `initial_stage`/`stage_edges` if conversational) + enter the entry gate. Returns the id. |
| `started?` | `started?(id)` | True once `RunStarted` applied (a fresh id loads empty). |
| `advance` | `advance(id)` | One autonomous gate step. No-op on a terminal or resting `await` gate; canned gates emit fixed text with no LLM call. Returns the reloaded `Run`. |
| `receive` | `receive(id, input:)` | One human-paced **turn**: record the inbound message, wake into the entry gate, run gates until rest/terminal, record the reply + fire `on_turn`. Returns the reply text. |
| `awaiting?` | `awaiting?(run)` | True if `run`'s current gate is an `await` gate (and not terminal). |
| `tag` | `tag(id, attrs)` | Stamp app dimensions outside a turn (e.g. entry profile). Returns the reloaded `Run`. |
| `run_to_completion` | `run_to_completion(input: nil, id: Shaolin::Id.generate)` | Synchronous in-process loop: `advance` until terminal **or** resting `await`. Returns the `Run`. |
| `load` | `load(id)` | `@repo.load(Run, id)`. |

`MAX_TURN_STEPS = 50` — a single `receive` turn that exceeds this raises
`Shaolin::Error` ("gate cycle?") to catch a non-terminating within-turn loop.

```ruby
runner = Shaolin::Harness::Runner.new(
  harness: TriageHarness, llm: Shaolin::Kernel["llm.client"],
  repo: Shaolin::Kernel["cqrs.aggregate_repository"],
  command_bus: Shaolin::Kernel["cqrs.command_bus"]
)
run = runner.run_to_completion(input: { text: "where is my money" })
run.completed?    # => true
run.output        # => { answer: "Here is your balance.", account: "balance:a1" }
run.tool_results  # => [{ name: "lookup", result: "balance:a1" }]
```

**Durable resume** — state lives in the event store, not the runner, so a brand
new `Runner` resumes mid-run with no re-work:

```ruby
id = runner.start(input: { text: "help" })
runner.advance(id)                       # classify step persisted; now at :respond
resumed = Shaolin::Harness::Runner.new(harness: TriageHarness, llm:, repo:, command_bus:)
resumed.advance(id) until resumed.load(id).terminal?   # finishes; classify NOT redone
```

### How a step works (internals worth knowing)

- **Prompt:** `gate.prompt` (string or `->(run)`) if present; else, for
  conversational harnesses, `harness.context_for(run)`; else raises.
- **Messages:** an array prompt passes through; anything else becomes a single
  `{role: "user", content: …}`.
- **Tools → commands:** for each `tool_call`, the mapped Command class is built
  with the model's arguments (`klass.new(**arguments)`) and dispatched on the
  bus. Results are **unwrapped** — `value!` on a success Result, `.failure` on a
  failure, else the raw value — then fed to the next gate via `tool_results`.
- **`response_format` / `params`** are resolved per-call (`->(run)` allowed) and
  passed to `llm.complete`.

> **Gotcha — tool schemas are minimal.** The Runner advertises each tool to the
> model as `{ name:, description: "", parameters: { type: "object", properties:
> {} } }`. Argument schemas are not derived from the Command class; rely on the
> tool name + your prompt, and validate args in the Command.

---

## 5. `Shaolin::Harness::Registry`

Maps `harness_name` → subclass so the durable `DriveReactor` (which only sees a
run's events) can find the definition. Subclasses auto-register on definition.

| Method | Purpose |
|---|---|
| `register(klass)` | Add a subclass (idempotent). Called by `Harness.inherited`. |
| `fetch(harness_name)` | Find by name; raises `ArgumentError` if none. |
| `all` | Copy of the registered list. |
| `reset!` | Clear (tests). |

```ruby
Shaolin::Harness::Registry.fetch("triage")  # => TriageHarness
```

---

## 6. Durable runtime — `DriveReactor` + `register_durable_provider!`

For a `shaolin worker` to advance runs step-by-step (crash-resumable), wire the
harness into the transactional outbox.

```ruby
Shaolin::Harness.register_durable_provider!   # registers the :harness provider
```

`register_durable_provider!` registers a `:harness` provider whose `start`
subscribes an enqueuer to `Events::GateEntered`: every `GateEntered` enqueues an
outbox job for `Shaolin::Harness::DriveReactor`. Register it **after**
`:active_record`, `:cqrs`, `:jobs`, `:llm`.

`Shaolin::Harness::DriveReactor#call(event)` then, per job:

1. Loads the run from `Shaolin::Kernel["cqrs.aggregate_repository"]`.
2. Returns early if the run is terminal, **or** if the event's `gate` is no
   longer the run's `current_gate` (idempotent against stale/redelivered
   `GateEntered` under at-least-once delivery).
3. Looks up the harness via `Registry.fetch(run.harness_name)`, builds a `Runner`
   (llm = `Kernel["llm.client"]`, bus = `Kernel["cqrs.command_bus"]`), and calls
   `advance(run_id)`.

Each `advance` appends the next `GateEntered`, which enqueues the next
`DriveReactor` job — the loop self-perpetuates across worker ticks.

> **ENV — run the worker with `WORKER_TX_PER_JOB=1`.** Each gate's LLM call is
> IO-bound, so hold the row lock per job, not per batch.

```ruby
# Drives via the outbox (one gate per Worker#run_once):
worker = Shaolin::Jobs::Worker.new(event_store: Shaolin::Kernel["cqrs.event_store"])
worker.run_once until runner.load(id).terminal?
```

---

## 7. `Shaolin::Conversation` — human-paced mode

`Conversation < Harness`. Same engine; the deltas: a turn is fed an inbound human
message, and the run **rests at an `await` gate** between turns. Adds a strict
funnel, a memory window, a persona context, per-turn hooks, and (opt-in) a
cross-user read model. `WINDOW_DEFAULT = 12`.

```ruby
class CompanionConvo < Shaolin::Conversation
  harness_name "companion"
  llm model: "gpt-4.1"

  stages :onboarding, :free, :offer, :subscriber          # the funnel (strict)
  edges  onboarding: :free, free: :offer, offer: :subscriber
  window 10                                                # recent-message memory
  context { |run| "You are a warm companion. stage=#{run.stage}" }

  gate :safety, entry: true, to: %i[respond refuse] do
    prompt { |run| "Safe? #{run.recent(1).last[:content]}" }
    on_result { |out, run| run.transition_to(out.text == "unsafe" ? :refuse : :respond) }
  end

  gate :respond, to: %i[awaiting_user] do                 # no prompt => persona context + history
    tools upgrade: Upgrade
    on_result do |out, run|
      run.advance_to(:free) if out.tool_used?(:upgrade)   # advance the funnel on tool use
      run.transition_to(:awaiting_user)                   # rest until the next message
    end
  end

  gate :refuse, reply: "I can't help with that.", to: %i[awaiting_user] do  # canned, no LLM call
    on_result { |_out, run| run.transition_to(:awaiting_user) }
  end

  gate :awaiting_user, await: true                        # resting state

  on_turn { |reply, run| } # optional deterministic always-do updates
end

session = CompanionConvo.session(id: "user-42")
session.receive("hello")   # => reply text
session.stage              # => "onboarding"
session.awaiting?          # => true
```

### Conversational DSL (`Shaolin::Conversation::DSL`, on top of the gate DSL)

| Method | Signature | Purpose |
|---|---|---|
| `stages` | `stages(*names)` | Declare funnel stages (strings); no args → current list. |
| `edges` | `edges(map = nil)` | Allowed funnel transitions, e.g. `edges(onboarding: :free, free: [:offer, :free])`. Strict — `advance_to` rejects undeclared jumps. No arg → current map. |
| `initial_stage` | `initial_stage(name = nil)` | The starting stage; defaults to the first declared stage. |
| `window` | `window(n = nil)` | Recent-message memory size; defaults to `WINDOW_DEFAULT` (12). |
| `context` | `context(&block)` | Persona/system line: `->(run){ "…" }`. Prepended (as a `system` message) to the window for prompt-less gates. |
| `on_turn` | `on_turn(&block)` | `\|reply, run\|` deterministic always-do hook, fired after a turn produces a reply. |
| `tags` | `tags(&block)` | `->(run){ { geo:, variant: } }` — computed each turn and merged onto the session (projected to `conversations_read`). |
| `stage_edges` | `stage_edges` | Normalized edges handed to the run at `start`; `nil` when no stages. |
| `context_for` | `context_for(run)` | Builds messages for a prompt-less gate: the `context` system line (if any) + `run.recent(window)`. |

> **No prompt = conversational responder.** A gate with no `prompt` uses
> `context_for(run)` (persona + recent history). That's the natural shape of the
> "reply to the user" gate.

### Multimodal turns

`received(content)` / `receive(id, input:)` accept:

- a **String** → one user message;
- an **OpenAI-style content array** (`[{type:"text",…}, {type:"image_url",…}]`)
  → passed through unchanged, persisted as structured content;
- a **`{ text:, images: [...] }` Hash** → normalized into content parts; each
  image may be a URL string or a full `image_url` hash.

```ruby
session.receive(text: "what is this?", images: ["https://x/img.png"])
# history.first[:content] => [{type:"text",text:"what is this?"},
#                             {type:"image_url",image_url:{url:"https://x/img.png"}}]
```

### Structured verdicts & canned gates

```ruby
gate :safety, entry: true, to: %i[respond refuse] do
  prompt { |run| "classify: #{run.recent(1).last[:content]}" }
  response_format { { type: "json_schema", json_schema: { name: "verdict" } } }
  on_result { |out, run| run.transition_to(out.data[:verdict] == "unsafe" ? :refuse : :respond) }
end
gate :refuse, reply: "I can't help with that.", to: %i[awaiting_user] do  # NO LLM call
  on_result { |_out, run| run.transition_to(:awaiting_user) }
end
```

A canned gate still records a synthetic `Responded` (so it flows into
history/`finish_turn`), and its `on_result` still runs (tools/transitions).

---

## 8. `Shaolin::Conversation::Session`

A handle bound to one session id; wraps a `Runner`.

```ruby
def initialize(harness:, id:, llm:, repo:, command_bus: nil)
```

| Method | Signature | Purpose |
|---|---|---|
| `receive` | `receive(message)` | Start the run on the first message, then run one turn; returns the reply text. |
| `run` | `run` | The loaded `Run` aggregate. |
| `stage` | `stage` | Current funnel stage. |
| `awaiting?` | `awaiting?` | Resting at an `await` gate? |
| `history` | `history` | Chat history. |
| `tags` | `tags` | App-dimension tags. |
| `tag` | `tag(**attrs)` | Stamp dimensions (starts the run if needed); returns `self`. |

Build one with the factory (defaults resolve from the kernel, so the common case
is just `MyConvo.session(id:)`):

```ruby
def self.session(id:, llm: nil, repo: nil, command_bus: nil)
#  llm           ||= Shaolin::Kernel["llm.client"]
#  repo          ||= Shaolin::Kernel["cqrs.aggregate_repository"]
#  command_bus   ||= Shaolin::Kernel["cqrs.command_bus"]
```

```ruby
session = CompanionConvo.session(id: "user-42")          # kernel-resolved deps
session.tag(geo: "DE", variant: "tripwire")
session.receive("hi there")
```

---

## 9. Cross-user read model — `conversations_read`

Opt-in CQRS read side: one **queryable row per session** (stage, turn count, last
activity, jsonb `tags`) so analytics / offer-engine / entitlement modules can
query the whole user base **without driving the session**. The run stream is the
write side; this is the read model, maintained by a **sync projection inside the
append transaction** (consistent with the write side).

```ruby
Shaolin::Conversation.register_read_model!   # register AFTER :cqrs
```

`register_read_model!` registers a `:conversation_read` provider whose `start`:
creates the table (`Schema.create!`), subscribes a `Projector` to `RunStarted`,
`StageChanged`, `MessageReceived`, `Tagged`, and registers the `Reader` facade as
`Shaolin::Kernel["conversations.read"]`.

### `Schema`

`Schema.create!` — advisory-locked (`SCHEMA_LOCK_KEY = 7_283_012`), idempotent.
Creates `conversations_read`:

| Column | Type | Notes |
|---|---|---|
| `session_id` | string, not null | primary key, unique index |
| `harness` | string | the harness name |
| `stage` | string | indexed |
| `turn_count` | integer, default 0 | incremented per `MessageReceived` |
| `last_turn_at` | datetime | from the message event timestamp |
| `tags` | jsonb, default `{}` | merged from `Tagged` |
| `created_at` / `updated_at` | timestamps | |

### `ReadRow` (`ActiveRecord::Base`, `primary_key = "session_id"`)

Scopes: `in_stage(stage)`, `with_min_turns(n, since: nil)` (`turn_count >= n`,
optionally `last_turn_at >= since`), `with_tags(attrs)` (AND-filter on jsonb,
e.g. `with_tags(geo: "DE", variant: "tripwire")`).

### `Projector#call(event)`

Sync subscriber that upserts the row: `RunStarted` sets harness/stage;
`StageChanged` sets stage; `MessageReceived` `turn_count += 1` + `last_turn_at`;
`Tagged` merges `tags` (string keys).

### `Reader` (the `conversations.read` facade)

`module_function` — read by any module without driving the session.

| Method | Signature | Purpose |
|---|---|---|
| `find` | `find(session_id)` | The `ReadRow` for a session (or nil). |
| `in_stage` | `in_stage(stage)` | Relation of rows in a stage. |
| `with_min_turns` | `with_min_turns(n, since: nil)` | Rows with ≥ n turns (optionally since a cutoff). |
| `all` | `all` | All rows. |
| `query` | `query(stage: nil, min_turns: nil, since: nil, tags: {})` | Compose all filters. |

```ruby
reader = Shaolin::Kernel["conversations.read"]
reader.find("user-42").stage                                  # => "free"
reader.in_stage("offer").pluck(:session_id)                   # everyone mid-funnel
reader.query(stage: "free", min_turns: 3, since: Date.today, tags: { geo: "DE" })
```

> **Gotcha — `tags` keys are strings.** Stamped via `run.tag` / `session.tag`,
> they're stored with stringified keys; query and read them as strings
> (`row.tags["geo"]`).

---

## 10. Wiring order (boot)

Providers register in order; the harness pieces go last:

```ruby
Shaolin::AR.register_provider!(config: ...)   # :active_record
Shaolin::CQRS.register_provider!              # :cqrs
Shaolin::Jobs.register_provider!              # :jobs  (for durable drive)
Shaolin::LLM.register_provider!(client: ...)  # :llm
Shaolin::Harness.register_durable_provider!   # :harness  (worker advances runs)
Shaolin::Conversation.register_read_model!    # :conversation_read  (optional)
Shaolin::Provider.start_all
```

Tools must be registered on the command bus:

```ruby
Shaolin::Kernel["cqrs.command_bus"].register(LookupAccount, ->(cmd) { "balance:#{cmd.id}" })
```

---

## Testing harnesses

Use `Shaolin::LLM::InMemory` — scripted, deterministic, no network. Hand it
`Completion`s (or hashes) to return in order; it records every call
(`llm.calls`) so you can assert on the messages / tools / `response_format` /
`params` sent.

```ruby
llm = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(tool_calls: [{ name: "lookup", arguments: { id: "a1" } }]),  # classify
  Shaolin::LLM::Completion.new(text: "Here is your balance.")                               # respond
)
runner = Shaolin::Harness::Runner.new(
  harness: TriageHarness, llm: llm,
  repo: Shaolin::Kernel["cqrs.aggregate_repository"],
  command_bus: Shaolin::Kernel["cqrs.command_bus"]
)
run = runner.run_to_completion(input: { text: "x" })
expect(llm.calls.last[:messages]).to include(a_hash_including(role: "user"))
```

Completion helpers handy in `on_result`: `out.text`, `out.data` (parsed
structured output, symbol keys), `out.tool_used?(:name)`, `out.tool_calls`,
`out.reasoning`, `out.usage`, `out.finish_reason`, `out.truncated?`.

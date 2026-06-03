# shaolin LLM harness — design spec

**Goal.** Make shaolin a native, *maximally cool* place to build LLM harnesses: gates with managed,
controllable state where each gate composes prompts and invokes tools. Model a harness as an
**event-sourced state machine** so runs are durable, auditable, resumable, and deterministically
replayable — guarantees most harness frameworks bolt on, here at the core.

**Positioning (honest).** Not a general LangGraph replacement (ecosystem + Python gravity win there).
The wedge: *durable, auditable, transactional, agent-ownable LLM harnesses inside a Ruby backend*,
with interop (tools may call out to HTTP/broker/MCP services, incl. Python). Win the Ruby-backend-native
niche, not the whole space.

## Decisions (locked with the user)

- **Execution modes: both.** A **durable** runtime (via outbox/worker — resume, audit, long autonomous
  runs) AND a **sync** in-process runtime (low latency for interactive turns). Same aggregate/events;
  two drivers. Build durable first; sync is a thin variant.
- **Tools are commands on the command bus.** A gate's tool call dispatches a Command; invocation and
  result are events (`ToolInvoked` / `ToolReturned`). Full audit + idempotency + reuse of the bus.
- **OpenAI first**, and the port must accommodate **realtime audio models** (OpenAI Realtime API).
  Slice 1 implements text `complete`; realtime audio is **phase 2** (port designed for it now).

## Gems

- **`shaolin-llm`** — the provider-agnostic LLM port + adapters. No harness logic.
- **`shaolin-harness`** — the gate DSL, the event-sourced `HarnessRun` aggregate, both runtimes, the
  prompt layer, and tool=command integration. Depends on shaolin-cqrs, shaolin-jobs, shaolin-llm.

## shaolin-llm

### Port

```ruby
module Shaolin::LLM
  # Request/response. messages: [{role:, content:}], tools: [tool schemas].
  # Returns a Completion(text:, tool_calls: [{name:, arguments:}], usage: {prompt:, completion:}).
  module Client
    def complete(messages:, tools: [], model: nil) = raise NotImplementedError
  end

  # Realtime/streaming session (phase 2). Opens a bidirectional session; yields
  # session events (response.delta, tool_call, turn.done) and accepts audio/text
  # frames. Audio bytes flow out-of-band; the harness records lifecycle + tool
  # calls + final transcript as domain events.
  module Realtime
    def session(model:, &block) = raise NotImplementedError
  end
end
```

### Adapters

- `Shaolin::LLM::InMemory` — scripted/canned responses (queue of Completions keyed by call order or a
  matcher). Deterministic; the backbone of harness tests and `verify.rb` (no network/keys).
- `Shaolin::LLM::OpenAI` — Chat Completions / Responses API over HTTP. Reads `ENV["OPENAI_API_KEY"]`
  (never hardcoded). Maps tool schemas ↔ OpenAI function-calling. Records `usage` for metrics.
  Realtime adapter: **phase 2** (WebSocket + audio framing).
- `:llm` provider registers `llm.client` (+ later `llm.realtime`) in the kernel.

## shaolin-harness

### DSL

```ruby
class Triage < Shaolin::Harness
  llm model: "gpt-4.1"                          # resolves llm.client from the kernel

  gate :classify, entry: true do
    prompt "prompts/classify.txt.erb"           # composed from run context
    tools  :lookup_account                       # only these commands callable here
    on_result do |out, run|
      run.transition_to(out.tool_used?(:lookup_account) ? :gather : :respond)
    end
  end

  gate :gather do
    prompt "prompts/gather.txt.erb"
    tools  :lookup_account, :fetch_invoices
    on_result { |out, run| run.transition_to(:respond) }
  end

  gate :respond, terminal: true do
    prompt "prompts/respond.txt.erb"
    on_result { |out, run| run.complete(answer: out.text) }
  end
end
```

- `gate` declares: prompt template, allowed tools (command names), and `on_result` (decides the
  transition / completion). Gates are small files under `gates/`.
- A gate may only call the tools it declares; `lint` can enforce this (a new dimension, like isolation).

### HarnessRun aggregate (event-sourced state machine)

Events: `RunStarted(harness, input)`, `GateEntered(gate)`, `PromptComposed(gate, rendered_prompt)`,
`LlmRequested(gate, messages, tools)`, `LlmResponded(gate, text, tool_calls, usage)`,
`ToolInvoked(name, args)`, `ToolReturned(name, result)`, `GateTransitioned(from, to)`,
`RunCompleted(output)`, `RunFailed(error)`. State (current gate, accumulated context/transcript) =
replay. The **rendered prompt is an event** → exact reproducibility on replay.

### Runtimes

- **Durable**: a reactor `on GateEntered` → compose prompt → `llm.complete` (in `shaolin worker`,
  retries/backoff) → append `LlmResponded` → tool calls dispatched as commands (`ToolInvoked` →
  `command_bus.call` → `ToolReturned`) → `on_result` decides next gate (`GateTransitioned` →
  `GateEntered`)… to a terminal gate. Each step durable via the outbox → **crash-resumable** (replay
  the stream, continue from the last gate). At-least-once → tool commands must be idempotent.
- **Sync**: the same step function run in-process in a loop (no outbox) for a single low-latency turn,
  appending the same events. Shares the aggregate + prompt + tool code with the durable runtime.

### Read model & tooling

- `read_models/run_record` — current gate, status, transcript — queryable over HTTP.
- `describe --json` — gates, transitions (static where derivable), declared tools, prompt files, llm
  model. `graph` — the gate graph (and B→A edges if a harness spans modules via topic reactors).
- Metrics: tokens + latency per gate via the existing structured logs / `/metrics`.

## Vertical slice (slice 1 — what we build first)

1. **shaolin-llm**: `Client` port + `InMemory` + `OpenAI` (text `complete`, ENV key) + `:llm` provider.
   Tests: InMemory unit; OpenAI mocked (live behind `OPENAI_API_KEY`, skipped otherwise).
2. **shaolin-harness**: `Harness`/`gate` DSL, `HarnessRun` aggregate + events, **sync** runtime, then
   **durable** runtime (reactor+worker), tool=command integration, run_record read model.
3. **Example** `examples/harness`: a 2–3 gate harness with one tool, `verify.rb` driving it on the
   InMemory stub (deterministic, no network) — proves gate→prompt→llm→tool(command)→transition→complete,
   in both sync and durable modes; shows resume.
4. `describe --json` + `graph` show the gate graph; `lint` clean.

## Phase 2 (after slice 1)

- **OpenAI Realtime (audio)**: WebSocket transport, audio frame in/out, server-VAD turns, function
  calls mid-session; session lifecycle + transcripts + tool calls captured as events, audio bytes
  out-of-band. This is a substantial separate workstream.
- Tool-allowlist lint dimension; prompt versioning/upcasting; multi-agent harnesses across modules.

## Acceptance criteria (E2E)

1. A harness with gates runs **sync** on the InMemory LLM: correct event sequence + terminal output +
   run_record reflects the final gate/answer.
2. The same harness runs **durable** (outbox → `worker.run_once` loop); killing mid-run and replaying
   resumes from the last gate (no duplicated terminal side effect).
3. A gate's tool call dispatches a **command** on the bus; `ToolInvoked`/`ToolReturned` recorded; result
   feeds the next prompt.
4. `describe --json` lists gates/tools/model; `graph` shows the gate graph; `lint` clean.
5. The **OpenAI** adapter performs a real `complete` when `OPENAI_API_KEY` is set (live, opt-in);
   otherwise that test is skipped and InMemory covers the logic.
6. Replaying a run's event stream with the InMemory stub is **deterministic** (the testing story).

## Conventions

- TDD; small files (< ~150 lines); kernel/provider decoupling (no cross-gem coupling besides ports).
- Secrets only via ENV; never written to files/commits. (`OPENAI_API_KEY`.)
- Reuse what exists: CQRS aggregate/buses, jobs outbox/worker, DI providers, Tenant, Redis cache/store
  (prompt/response cache, run context), describe/lint.

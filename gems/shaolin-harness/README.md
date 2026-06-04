# shaolin-harness

Build LLM harnesses as **event-sourced gate state machines** — durable, auditable, and
deterministically replayable, because every step (prompt, response, tool call, transition) is a
domain event. Gates compose prompts and invoke tools; tools are **commands on the command bus**.

```ruby
class Triage < Shaolin::Harness
  harness_name "triage"
  llm model: "gpt-4.1"

  gate :classify, entry: true do
    prompt { |run| "Classify the request: #{run.input[:text]}" }
    tools  lookup: LookupAccount               # tool name the model sees => Command class
    on_result { |out, run| run.transition_to(out.tool_used?(:lookup) ? :respond : :reject) }
  end

  gate :respond, terminal: true do
    prompt { |run| "Answer using #{run.tool_results.last[:result]}" }
    on_result { |out, run| run.complete(answer: out.text) }
  end
end

runner = Shaolin::Harness::Runner.new(
  harness: Triage, llm: Shaolin::Kernel["llm.client"],
  repo: Shaolin::Kernel["cqrs.aggregate_repository"], command_bus: Shaolin::Kernel["cqrs.command_bus"]
)
run = runner.run_to_completion(input: { text: "where is my money" })   # sync
run.output   # => { answer: "..." }
```

## Two runtimes

- **Sync** — `run_to_completion(input:)` drives the gates in-process. Low latency for an interactive
  turn. Each gate step persists its events; the LLM/tool IO happens OUTSIDE the DB transaction.
- **Durable** — `start(input:)` then `advance(id)` per gate. Each `advance` is one atomic step, so a
  crash before commit replays that step (at-least-once on LLM/tool calls — keep tools idempotent) and a
  crash after it resumes at the next gate. A fresh `Runner` continues a run purely from its event
  stream (state lives in the store, not the process). A worker can drive `advance` per `GateEntered`.

## Why event-sourced

The run's event stream IS its history: full audit of every prompt/response/tool/transition, crash
resume, time-travel, and **deterministic replay with `Shaolin::LLM::InMemory`** for testing harness
logic without a network.

`Triage.describe` returns a machine-readable map (gates, transitions, tools, model) for agents/tooling.
Realtime/audio (OpenAI Realtime) is a separate, later port.

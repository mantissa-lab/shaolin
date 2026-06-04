# shaolin-llm

Provider-agnostic LLM port for shaolin: chat completions + function/tool calling.

```ruby
client = Shaolin::Kernel["llm.client"]          # or Shaolin::LLM::OpenAI.new / InMemory.new
completion = client.complete(
  messages: [{ role: "user", content: "Which intent? billing or support?" }],
  tools: [{ name: "lookup_account", description: "...", parameters: { } }]
)
completion.text            # => "billing"
completion.tool_calls      # => [{ name: "lookup_account", arguments: { id: "a1" } }]
completion.usage           # token counts
```

- `Shaolin::LLM::Client` — the port (`#complete(messages:, tools:, model:)` → `Completion`).
- `Shaolin::LLM::InMemory` — scripted, records calls. The backbone of deterministic harness tests
  (no network, no keys).
- `Shaolin::LLM::OpenAI` — Chat Completions over stdlib Net::HTTP (no extra gem). Key from
  `ENV["OPENAI_API_KEY"]` only. Inject `transport:` in tests to avoid the network.
- `Shaolin::LLM.register_provider!(client:)` registers `llm.client` (defaults to the OpenAI adapter
  from `OPENAI_MODEL`).

## Realtime / audio (`Shaolin::LLM::Realtime`)

A provider-agnostic streaming substrate — build realtime/voice on any backend:

- normalized session `Event`s: `session_started`, `transcript_delta`, `audio_delta`, `tool_call`,
  `turn_completed`, `error`, `session_closed`;
- `Audio` (PCM16 base64 + framing); a `Session`/`Client` port —
  `send_audio` / `send_text` / `commit` / `tool_result` / `close` + `on_event`;
- `Realtime::InMemory` — scriptable adapter to build & test voice/tool flows with no provider/network;
- `Realtime::OpenAI` — maps OpenAI's Realtime WebSocket both ways via an injectable transport
  (unit-tested without a network; wrap a WebSocket gem for the live socket).

See `examples/realtime`. Live tests are opt-in: `RUN_LIVE=1`.

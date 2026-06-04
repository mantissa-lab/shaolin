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

Realtime/audio (OpenAI Realtime) is a separate, later port. Live tests are opt-in: `RUN_LIVE=1`.

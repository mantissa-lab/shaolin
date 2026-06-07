# LLM: chat, tools, reasoning, structured output, audio, realtime

`shaolin-llm` is a provider-agnostic LLM layer: a chat-completion port (`Shaolin::LLM::Client`)
with `InMemory` and `OpenAI` adapters, a uniform `Completion` result shape (text + reasoning +
tool calls + usage + structured data), an audio port (TTS/STT), and a separate realtime/audio
streaming substrate (`Shaolin::LLM::Realtime`). It registers into the kernel via the `:llm` and
`:realtime` providers.

```ruby
require "shaolin/llm"   # pulls Completion, Client, InMemory, OpenAI, provider, Realtime
```

Everything in this layer is pure Ruby stdlib (`Net::HTTP`, `json`, `base64`) plus `concurrent-ruby`
for the optional concurrency cap — no provider SDK. API keys come **only** from `ENV`.

---

## 1. `Shaolin::LLM::Client` — the chat-completion port

A module mixed into every adapter. All three methods raise `NotImplementedError` by default; an
adapter overrides the ones it supports.

| Method | Signature | Purpose |
| --- | --- | --- |
| `complete` | `complete(messages:, tools: [], model: nil, response_format: nil, params: {})` | Chat completion → `Completion`. |
| `speak` | `speak(_text, voice: nil, format: nil, model: nil)` | TTS: text → audio bytes (optional). |
| `transcribe` | `transcribe(_audio, language: nil, model: nil)` | STT: audio bytes → text (optional). |

**`complete` arguments**

- `messages:` — array of `{ role:, content: }` hashes (required).
- `tools:` — array of function/tool schemas `{ name:, description:, parameters: }`. Default `[]`.
- `model:` — override the adapter's default model. Default `nil`.
- `response_format:` — opt-in structured output request, e.g.
  `{ type: "json_schema", json_schema: {...} }` or `{ type: "json_object" }`. The parsed object
  comes back on `Completion#data`. Default `nil`.
- `params:` — extra sampling params merged into the request (`max_tokens`, `temperature`, `top_p`,
  `stop`, …), overriding adapter defaults. Default `{}`. **Gotcha:** crucial for reasoning models
  whose server default `max_tokens` would otherwise truncate the reply.

```ruby
client = Shaolin::Kernel["llm.client"]          # any Client
res = client.complete(
  messages: [{ role: "user", content: "Reply with OK." }],
  params: { max_tokens: 64, temperature: 0 }
)
res.text  # => "OK"
```

---

## 2. `Shaolin::LLM::Completion` — the result shape

Transport-agnostic result returned by every adapter. Constructor:

```ruby
Completion.new(text: nil, reasoning: nil, tool_calls: [], usage: {}, data: nil, finish_reason: nil)
```

| Reader | Meaning |
| --- | --- |
| `text` | Clean free-text reply (reasoning lifted out). |
| `reasoning` | Chain-of-thought trace when the provider exposes it (separate field or lifted inline `<think>` block); `nil` otherwise. |
| `tool_calls` | Tool calls the model requested: `[{ name:, arguments: {} }]`. Normalized to `[]` if `nil`. |
| `usage` | Token usage hash (string keys as the provider returns them). Normalized to `{}` if `nil`. |
| `data` | Parsed structured object (Hash with **symbol** keys) when `response_format:` was requested; `nil` otherwise. |
| `finish_reason` | The choice's stop reason: `"stop"` / `"length"` / `"tool_calls"` / … |

| Predicate | Returns |
| --- | --- |
| `tool_calls?` | `true` if any tool calls present. |
| `tool_used?(name)` | `true` if a tool with that name was called (string-compared). |
| `reasoning?` | `true` if `reasoning` is present and non-empty. |
| `data?` | `true` if `data` is non-nil. |
| `truncated?` | `true` if `finish_reason == "length"` — reply cut off at the token budget (e.g. a reasoning model that spent its whole budget inside `<think>` and returned empty `text`). Retry with a higher `max_tokens`. |
| `to_h` | `{ text:, reasoning:, tool_calls:, usage:, data:, finish_reason: }`. |

```ruby
c = Shaolin::LLM::Completion.new(text: "billing", reasoning: "user mentions an invoice")
c.reasoning?              # => true
c.to_h[:finish_reason]    # => nil
```

**Harness tip:** persist `reasoning` in the event log (auditable replay) but show only `text` to
the user.

---

## 3. `Shaolin::LLM::InMemory` — scripted in-process adapter

`include Client`. Network-free, key-free; hand it `Completion`s (or hashes) to return in order;
records every call for assertions. For tests and deterministic harness replay.

```ruby
InMemory.new(*responses, speak: [], transcribe: [])
```

- `*responses` — `Completion` objects and/or `{ ... }` hashes (flattened); returned FIFO. A hash is
  splatted into `Completion.new(**hash)`. Running out raises `"InMemory LLM: no scripted response left (call #N)"`.
- `speak:` / `transcribe:` — arrays of canned audio/text results, shifted FIFO; empty + called
  raises `"no scripted speak response left"` / `"no scripted transcribe response left"`.
- `calls` (reader) — every recorded call. `complete` records
  `{ messages:, tools:, model:, response_format:, params: }`; audio records
  `{ audio: :speak | :transcribe, ... }`.

```ruby
llm = Shaolin::LLM::InMemory.new(
  Shaolin::LLM::Completion.new(text: "first"),
  { text: "second", tool_calls: [{ name: "lookup", arguments: { id: "1" } }] }
)
a = llm.complete(messages: [{ role: "user", content: "hi" }])
b = llm.complete(messages: [{ role: "user", content: "more" }], tools: [{ name: "lookup" }])
a.text                       # => "first"
b.tool_used?("lookup")       # => true
llm.calls.last[:tools]       # => [{ name: "lookup" }]

audio = Shaolin::LLM::InMemory.new(speak: ["AUDIO"], transcribe: ["hello world"])
audio.speak("hi", voice: "alloy")        # => "AUDIO"
audio.transcribe("WAV", language: "en")  # => "hello world"
audio.calls.map { |c| c[:audio] }        # => [:speak, :transcribe]
```

---

## 4. `Shaolin::LLM::OpenAI` — OpenAI Chat Completions adapter

`include Client`. Pure `Net::HTTP` (text + function/tool calling + structured output + audio).

```ruby
OpenAI.new(
  api_key:        ENV["OPENAI_API_KEY"],
  model:          "gpt-4.1",
  base:           "https://api.openai.com/v1",
  transport:      nil,
  reasoning_tag:  nil,
  open_timeout:   15,
  read_timeout:   600,
  max_retries:    2,
  retry_backoff:  [0.5, 2.0],
  default_params: {},
  max_concurrency: nil,
  tts_async:      nil
)
```

| Knob | Default | Purpose / gotcha |
| --- | --- | --- |
| `api_key:` | `ENV["OPENAI_API_KEY"]` | Bearer token. **Never hardcode.** `complete` raises `"OPENAI_API_KEY not set"` if nil/empty (unless `transport:` injected). |
| `model:` | `"gpt-4.1"` | Default model; overridable per call via `complete(model:)`. |
| `base:` | `"https://api.openai.com/v1"` | API base URL — point at any OpenAI-compatible gateway (self-hosted Qwen, etc.). |
| `transport:` | `nil` | Inject a `->(path, body) { hash }` lambda to bypass the network (tests). When set, no key is required and timeouts/HTTP are skipped (concurrency + retries still wrap it for `complete`). |
| `reasoning_tag:` | `nil` | When set (e.g. `"think"`), inline `<think>…</think>` block(s) in content are lifted into `Completion#reasoning`; remaining content becomes clean `text`. Needed for models like Qwen. Off → inline tags left untouched. |
| `open_timeout:` | `15` | Connect timeout (s). |
| `read_timeout:` | `600` | Read timeout (s) — generous because reasoning models routinely exceed `Net::HTTP`'s 60s default on one reply. |
| `max_retries:` | `2` (→ up to 3 attempts) | Retries **only** transient failures (5xx, timeouts, dropped sockets). 4xx never retry. `0` disables. |
| `retry_backoff:` | `[0.5, 2.0]` | Per-attempt sleep (s) between retries; falls back to the last value, then `0`. |
| `default_params:` | `{}` | Sampling params applied to every call (e.g. `{ max_tokens: 4096 }`); per-call `params:` overrides them. |
| `max_concurrency:` | `nil` | When set, a `Concurrent::Semaphore` bounds in-flight calls; extra callers **block** past the cap. Retries happen inside the held permit (no thundering herd). |
| `tts_async:` | `nil` | Config for async/job-based TTS backends (see `speak`). `nil` = sync `/audio/speech`. |

**ENV vars:** `OPENAI_API_KEY` (the default `api_key:`). The `:llm` provider also reads `OPENAI_MODEL`.

### `complete(messages:, tools: [], model: nil, response_format: nil, params: {})`

POSTs `/chat/completions`. Body = `{ model:, messages: }` merged with `default_params` then per-call
`params`; tools become `{ type: "function", function: <schema> }`; `response_format` passed through
when set. Maps `choices[0]`: extracts reasoning (provider `reasoning_content`/`reasoning` field wins,
else inline `<reasoning_tag>` stripping), parses `tool_calls` (arguments JSON → symbol-key hash),
copies `usage`, parses structured `data` (only when `response_format:` set), surfaces `finish_reason`.

```ruby
# tool calling
res = openai.complete(
  messages: [{ role: "user", content: "balance for a1?" }],
  tools:    [{ name: "lookup_account", description: "...", parameters: {} }]
)
res.tool_calls  # => [{ name: "lookup_account", arguments: { id: "a1" } }]

# structured output (data has symbol keys)
rf  = { type: "json_schema", json_schema: { name: "verdict" } }
res = openai.complete(messages: [...], response_format: rf)
res.data        # => { verdict: "unsafe", reason: "abuse" }

# reasoning model: separate field OR inline <think> via reasoning_tag
qwen = Shaolin::LLM::OpenAI.new(base: "http://localhost:8000/v1", reasoning_tag: "think")
qwen.complete(messages: [...], params: { max_tokens: 4096 }).reasoning
```

**Errors:** non-2xx raises `Shaolin::LLM::HTTPError` carrying `status` + truncated body (instead of
JSON-parsing an HTML gateway page).

### `Shaolin::LLM::HTTPError < Shaolin::Error`

Raised on a non-2xx response. Readers `status` (Integer) and `body` (first 500 chars).
`server_error?` → `status >= 500`. Only `server_error?` HTTPErrors (and the `RETRYABLE` socket
exceptions) are retried.

```ruby
RETRYABLE = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
             Errno::ECONNRESET, EOFError, SocketError]
```

```ruby
begin
  openai.complete(messages: [...])
rescue Shaolin::LLM::HTTPError => e
  warn "LLM #{e.status}: #{e.body}" if e.server_error?
end
```

### `speak(text, voice: "alloy", format: "mp3", model: "tts-1")` — TTS

POSTs `/audio/speech`, returns audio **bytes**. Sync by default. When `tts_async:` is configured
and the submit returns `202`, the job is polled to completion behind this call. Shares the
timeout/retry/HTTPError/concurrency layer.

`tts_async:` config shape:
`{ result_path: "/audio/result/{id}", done: ->(res) { ... }, poll_interval: 1.0, max_wait: 120 }`
— `{id}` is substituted from the submit response's `job_id`/`id`; `done` is called with each raw
`Net::HTTPResponse` and returns truthy when finished; `poll_interval` (s, default `1.0`), `max_wait`
(s, default `120`) → on expiry raises `HTTPError` status `202`.

```ruby
bytes = openai.speak("Hello there", voice: "alloy", format: "mp3")

async = Shaolin::LLM::OpenAI.new(tts_async: {
  result_path: "/audio/result/{id}", done: ->(r) { r.code == "200" },
  poll_interval: 1.0, max_wait: 60
})
async.speak("hi")   # submits 202 job, polls /audio/result/<id>, returns bytes
```

### `transcribe(audio_bytes, language: nil, model: "whisper-1", filename: "audio.wav", content_type: "audio/wav")` — STT

Multipart POST `/audio/transcriptions`; returns the parsed `"text"` string. `language` omitted from
the form when `nil`.

```ruby
text = openai.transcribe(File.binread("clip.wav"), language: "en")
```

---

## 5. The `:llm` provider

```ruby
Shaolin::LLM.register_provider!(client: nil)
```

Registers the chat client as `llm.client` in the kernel at provider `start`. Pass `client:`
(e.g. `InMemory` in tests); default builds `OpenAI.new(model: ENV.fetch("OPENAI_MODEL", "gpt-4.1"))`.

```ruby
# production (from ENV)
Shaolin::LLM.register_provider!
# tests
Shaolin::LLM.register_provider!(client: Shaolin::LLM::InMemory.new({ text: "ok" }))
Shaolin::Provider.start_all
Shaolin::Kernel["llm.client"].complete(messages: [{ role: "user", content: "hi" }])
```

---

## 6. `Shaolin::LLM::Realtime` — streaming / bidirectional / audio substrate

A separate substrate (phase 2) for live voice/realtime apps: normalized session events, audio
helpers, a `Session`/`Client` port, an `InMemory` adapter for provider-free tests, and an `OpenAI`
Realtime adapter over an injected WebSocket transport.

```ruby
require "shaolin/llm"   # realtime loaded via shaolin/llm
R = Shaolin::LLM::Realtime
```

### 6.1 `Realtime::Audio` — audio primitives (`module_function`)

Audio crosses the wire base64-encoded. Normalizes encode/decode and names the default PCM format.

| Member | Value / signature | Purpose |
| --- | --- | --- |
| `FORMAT` | `{ encoding: "pcm16", sample_rate: 24_000, channels: 1 }` (frozen) | De-facto realtime I/O format (16-bit LE PCM, 24 kHz, mono). |
| `encode(bytes)` | → base64 string | `Base64.strict_encode64`. |
| `decode(b64)` | → bytes | `Base64.strict_decode64`. |
| `frames(bytes, ms: 20, format: FORMAT)` | → array of byte-strings | Split a PCM buffer into ~`ms`-ms frames for paced sends. |

```ruby
b64 = R::Audio.encode("\x00\x01".b)
R::Audio.decode(b64)                 # => "\x00\x01"
R::Audio.frames(pcm, ms: 20)         # => ["...20ms...", "...20ms...", ...]
```

### 6.2 `Realtime::Event` — normalized session event

The single vocabulary every adapter maps its provider's wire events into.

```ruby
Event.new(type, **data)   # type coerced to Symbol; data is the payload
```

`event[:key]` reads `data`; `event.to_h` → `{ type:, **data }`; `event.type`, `event.data` readers.

`Event::TYPES` (allowed `type`s) and their typical `data`:

| Type | Data |
| --- | --- |
| `:session_started` | `{}` |
| `:transcript_delta` | `{ text:, role: }` — streamed text (you or model) |
| `:audio_delta` | `{ audio: <bytes> }` — streamed output audio |
| `:tool_call` | `{ id:, name:, arguments: }` — model wants a tool |
| `:turn_completed` | `{ transcript: }` — end of a model turn |
| `:error` | `{ message: }` |
| `:session_closed` | `{}` |

```ruby
ev = Event.new(:transcript_delta, text: "hi", role: "assistant")
ev.type     # => :transcript_delta
ev[:text]   # => "hi"
```

### 6.3 `Realtime::Session` — the live bidirectional session (port)

The interface app/harness code talks to. Register handlers with `on_event`; push input with
`send_audio`/`send_text`; `commit` an input turn; answer a `:tool_call` with `tool_result`;
`close`. Adapters subclass and `emit` normalized `Event`s.

| Method | Purpose |
| --- | --- |
| `on_event(&block)` | Register an event handler (multiple allowed). |
| `emit(event)` | Adapter→app delivery: calls every handler, returns the event. |
| `send_audio(bytes)` | Push input audio (adapter-implemented). |
| `send_text(text)` | Push input text (adapter-implemented). |
| `commit` | Commit the current input turn (adapter-implemented). |
| `tool_result(call_id, result)` | Answer a `:tool_call` (adapter-implemented). |
| `close` | Close the session (adapter-implemented). |

The write-side methods raise `NotImplementedError` on the base class.

### 6.4 `Realtime::Client` — the connection port

```ruby
connect(model:, tools: [], instructions: nil)   # → a Realtime::Session
```

Open a session for a model with optional `tools` and system `instructions`. Mixed into adapters.

### 6.5 `Realtime::InMemory` — scriptable provider-free adapter

`include Client`. Script the model's turns as lists of events; each `commit` plays the next turn to
the handlers. Records everything the app sent.

| Member | Purpose |
| --- | --- |
| `InMemory.new` | No args. |
| `script_turn(events)` | Queue a model turn (array of `Event`s) for the next `commit`; returns `self` (chainable). |
| `connect(model:, tools: [], instructions: nil)` | Build + store the backing `Session`; returns it. |
| `session` (reader) | The session backed by the scripted turns. |

The nested `InMemory::Session < Realtime::Session` records `sent_audio`, `sent_text`,
`tool_results` (`[[call_id, result], …]`), `closed`. First `commit` emits `:session_started` before
playing turn 1; `close` is idempotent and emits `:session_closed` once.

```ruby
client = R::InMemory.new
client.script_turn([
  Event.new(:transcript_delta, text: "Let me look that up.", role: "assistant"),
  Event.new(:tool_call, id: "c1", name: "lookup_account", arguments: { id: "a1" })
])
client.script_turn([
  Event.new(:transcript_delta, text: "Your balance is $5.", role: "assistant"),
  Event.new(:turn_completed, transcript: "Your balance is $5.")
])

received = []
s = client.connect(model: "stub", tools: [{ name: "lookup_account" }])
s.on_event { |e| received << e }

s.send_audio("PCM_FROM_MIC")
s.commit                                   # => session_started + turn 1
call = received.find { |e| e.type == :tool_call }
s.tool_result(call[:id], "balance:$5")
s.commit                                   # => turn 2
s.close

received.map(&:type)
# => [:session_started, :transcript_delta, :tool_call, :transcript_delta, :turn_completed, :session_closed]
s.session.tool_results                     # via client.session → [["c1", "balance:$5"]]
```

### 6.6 `Realtime::OpenAI` — OpenAI Realtime adapter

`include Client`. Maps OpenAI's WebSocket wire events to normalized `Event`s and session writes to
OpenAI client events. The raw socket is an injected `transport`.

```ruby
OpenAI.new(api_key: ENV["OPENAI_API_KEY"], model: "gpt-4o-realtime-preview", transport: nil)
```

- **`transport:`** must respond to `#send(hash)`, `#on_message { |hash| }`, `#close`. Tests use a
  fake. For live use, wrap a WebSocket gem (faye-websocket / async-websocket) to
  `wss://api.openai.com/v1/realtime?model=...` with the `Authorization` header.
- **`connect(model: nil, tools: [], instructions: nil)`** → a `Realtime::OpenAI::Session`. Raises
  `"inject a WebSocket transport ..."` if no `transport:` was given.

`Realtime::OpenAI.translate(ev)` (class method) — OpenAI server event Hash → normalized `Event`
(or `nil` to ignore, e.g. `rate_limits.updated`):

| Wire `type` | → Event |
| --- | --- |
| `session.created` | `:session_started` |
| `response.audio_transcript.delta`, `response.text.delta` | `:transcript_delta` `{ text: delta, role: "assistant" }` |
| `response.audio.delta` | `:audio_delta` `{ audio: Audio.decode(delta) }` |
| `response.function_call_arguments.done` | `:tool_call` `{ id: call_id, name:, arguments: }` |
| `response.done` | `:turn_completed` |
| `error` | `:error` `{ message: error.message }` |
| (anything else) | `nil` (ignored) |

`Realtime::OpenAI.parse_args(json)` — JSON string → symbol-key hash (`{}` on empty/parse error).

The nested `Session` maps writes to client events: `send_audio` →
`input_audio_buffer.append` (base64), `send_text` → `conversation.item.create` (input_text),
`commit` → `input_audio_buffer.commit` + `response.create`, `tool_result` →
`conversation.item.create` (`function_call_output`), `close` → `transport.close`. On construction it
sends `session.update` with `instructions`/`tools` (when present) and wires
`transport.on_message` → `dispatch` → `translate` → `emit`.

```ruby
adapter = R::OpenAI.new(transport: my_ws)         # my_ws responds to send/on_message/close
session = adapter.connect(tools: [{ name: "lookup" }], instructions: "Be brief.")
session.on_event { |e| handle(e) }
session.send_audio(pcm_bytes)
session.commit                                    # commits buffer + asks for a response
# ... on a :tool_call event:
session.tool_result("c1", "balance:$5")
```

### 6.7 The `:realtime` provider

```ruby
Shaolin::LLM::Realtime.register_provider!(client:)   # client: is required
```

Registers the given realtime client as `realtime.client` in the kernel at `start`.

```ruby
Shaolin::LLM::Realtime.register_provider!(client: Shaolin::LLM::Realtime::InMemory.new)
Shaolin::Provider.start_all
Shaolin::Kernel["realtime.client"]   # => the client
```

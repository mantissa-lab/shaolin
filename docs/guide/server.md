# Server: Falcon/Puma, timeouts, graceful shutdown

`shaolin-server` serves a Rack app via a pluggable adapter (Falcon by default, Puma opt-in),
emits one structured startup line, installs SIGTERM/SIGINT traps for graceful shutdown, and —
on Falcon only — enforces an optional cooperative per-request deadline. All config is 12-factor
(read from ENV). Requiring it loads everything:

```ruby
require "shaolin/server"   # loads version, Config, Adapters (Puma + Falcon), Runner
```

Gem deps: `shaolin-core`, `rack ~> 3.0`, `puma ~> 6.4`, `falcon >= 0.47`. Ruby `>= 4.0.0`.
`Shaolin::Server::VERSION` is `"0.1.0"`.

---

## Quick start

```ruby
require "shaolin/server"

rack_app = ->(_env) { [200, { "content-type" => "text/plain" }, ["pong"]] }

# Blocks, serving on $HOST:$PORT via the $SHAOLIN_SERVER adapter (default Falcon),
# until SIGTERM/SIGINT triggers a graceful stop.
Shaolin::Server.run(rack_app)
```

---

## `Shaolin::Server.run`

```ruby
Shaolin::Server.run(rack_app, config: Config.new, adapter: nil) # => adapter.start result (blocks)
```

Serves `rack_app` through the configured adapter. **Blocks** until the adapter is stopped.

1. `adapter ||= Adapters.build(config.adapter)` — builds the adapter from `config.adapter` unless one is passed.
2. `banner(config)` — emits the `server.started` log line (below).
3. `install_traps(adapter, config)` — wires SIGTERM/SIGINT to `adapter.stop`.
4. `adapter.start(rack_app, config)` — hands off to the adapter (this is what blocks).

| Arg | Default | Purpose |
|---|---|---|
| `rack_app` (positional) | — | Any Rack-callable (`#call(env) -> [status, headers, body]`). |
| `config:` | `Config.new` | A `Shaolin::Server::Config` (reads ENV by default). |
| `adapter:` | `nil` | Inject a custom adapter (any object responding to `start(app, config)` + `stop(timeout:)`); otherwise built from `config.adapter`. |

```ruby
# Inject a no-op adapter (e.g. in tests) — run returns immediately instead of blocking.
fake = Class.new { def start(_a, _c) = nil; def stop(**) = nil }.new
Shaolin::Server.run(rack_app, config: Shaolin::Server::Config.new(env: {}), adapter: fake)
```

### `Shaolin::Server.banner`

```ruby
Shaolin::Server.banner(config) # => emits "server.started" via Shaolin::Log.emit
```

Emits exactly one structured `info` line (respects `SHAOLIN_LOG`) answering "did it start, where,
which env, how is it bounded?". Fields:

| Field | Value source |
|---|---|
| `url` | `"http://#{config.host}:#{config.port}"` |
| `adapter` | `config.adapter` (Symbol) |
| `env` | `ENV["SHAOLIN_ENV"]` (default `"development"`) |
| `db_pool` | `Integer(ENV["DB_POOL"])` (default `5`) |
| `web_concurrency` | `ENV["SHAOLIN_WEB_CONCURRENCY"]` or `"unbounded"` |
| `graceful_timeout` | `config.graceful_timeout` |

> Gotcha: `db_pool` is parsed with `Integer(...)` — a non-numeric `DB_POOL` raises at banner time.

### `Shaolin::Server.install_traps`

```ruby
Shaolin::Server.install_traps(adapter, config) # traps TERM and INT
```

Installs `Signal.trap` for `TERM` and `INT`. Each handler spawns a **new thread** that calls
`adapter.stop(timeout: config.graceful_timeout)`. The thread is required because trap context is
restricted (you cannot do most work directly inside a trap). Cloud Run sends SIGTERM with a ~10s
window, which matches the default `graceful_timeout`.

---

## `Shaolin::Server::Config`

12-factor config read from ENV at construction. Falcon is the async-first default; Puma is opt-in.

```ruby
Shaolin::Server::Config.new(env: ENV)
```

Read-only attributes (`attr_reader`): `host`, `port`, `adapter`, `graceful_timeout`, `request_timeout`.

| Attribute | ENV var | Default | Parsing / notes |
|---|---|---|---|
| `host` | `HOST` | `"0.0.0.0"` | String. |
| `port` | `PORT` | `"8080"` → `8080` | `Integer(...)` — non-numeric raises. |
| `adapter` | `SHAOLIN_SERVER` | `"falcon"` → `:falcon` | `.to_sym`; only `:falcon`/`:puma` are valid at build time. |
| `graceful_timeout` | `SHAOLIN_GRACEFUL_TIMEOUT` | `"10"` → `10` | `Integer(...)`, seconds. |
| `request_timeout` | `SHAOLIN_REQUEST_TIMEOUT` | unset → `nil` | `Float(...)` if set, seconds; `nil` = off. **Falcon only.** |

```ruby
cfg = Shaolin::Server::Config.new(env: { "PORT" => "3000", "SHAOLIN_SERVER" => "puma" })
cfg.port              # => 3000
cfg.adapter           # => :puma
cfg.graceful_timeout  # => 10
cfg.request_timeout   # => nil
```

> Gotcha: `request_timeout` is only enforced by the Falcon adapter (and only when running inside an
> Async reactor). Under Puma it is read but never applied — use `Rack::Timeout` or Puma's own
> timeouts there.

---

## `Shaolin::Server::Adapters`

Factory for the two built-in adapters.

```ruby
Shaolin::Server::Adapters.build(name) # => Falcon.new | Puma.new
```

`name` is symbolized (`name.to_sym`). `:falcon` → `Adapters::Falcon`, `:puma` → `Adapters::Puma`;
anything else raises `Shaolin::Error` (`"unknown server adapter: <name> (expected :falcon or :puma)"`).

```ruby
Shaolin::Server::Adapters.build(:falcon)   # => #<Shaolin::Server::Adapters::Falcon>
Shaolin::Server::Adapters.build(:webrick)  # => raises Shaolin::Error
```

Both adapters share the same duck-typed interface:

| Method | Signature | Contract |
|---|---|---|
| `start` | `start(rack_app, config)` | Bind + serve; **blocks** until stopped. |
| `stop` | `stop(timeout: 10)` | Stop serving so `start` returns; safe to call from another thread. |

### `Adapters::Falcon` (default)

Async / fiber-per-request. `start` runs the async reactor until stopped.

```ruby
def start(rack_app, config)
  rack_app = Timeout.new(rack_app, config.request_timeout) if config.request_timeout
  app = Protocol::Rack::Adapter.new(rack_app)
  endpoint = Async::HTTP::Endpoint.parse("http://#{config.host}:#{config.port}")
  server = ::Falcon::Server.new(app, endpoint)

  @thread = Thread.current
  Async do |task|
    server.run
    task.children&.each(&:wait)
  end
end

def stop(timeout: 10)
  @thread&.raise(Async::Stop)   # unwind the Async{} block in the reactor thread
rescue StandardError
  nil
end
```

- When `config.request_timeout` is set, the app is wrapped in `Timeout` (cooperative per-request deadline).
- `stop` records the reactor thread in `start` (`@thread`) and raises `Async::Stop` in it; this unwinds
  the `Async{}` block so `start` returns. Errors during stop are swallowed.
- `stop`'s `timeout:` arg is accepted for interface symmetry but **not** used by Falcon (the deadline is
  per-request via `Timeout`, and stop is an immediate reactor unwind).

```ruby
adapter = Shaolin::Server::Adapters::Falcon.new
cfg = Shaolin::Server::Config.new(env: { "HOST" => "127.0.0.1", "PORT" => "9292" })
t = Thread.new { adapter.start(->(_e) { [200, {}, ["ok"]] }, cfg) }  # blocks in its thread
# ... serve requests ...
adapter.stop(timeout: 2)
t.join(5)
```

### `Adapters::Puma` (opt-in)

Thread-based. Enable with `SHAOLIN_SERVER=puma`.

```ruby
def start(rack_app, config)
  @server = ::Puma::Server.new(rack_app)
  @server.add_tcp_listener(config.host, config.port)
  @server.run.join
end

def stop(timeout: 10)
  @server&.stop(true)   # true = wait for in-flight requests
end
```

- `start` blocks on `@server.run.join`.
- `stop(true)` performs a graceful stop, waiting for in-flight requests. Like Falcon, the `timeout:`
  kwarg is accepted but not passed to Puma.
- `config.request_timeout` is **not** honored here — Falcon-only.

```ruby
adapter = Shaolin::Server::Adapters::Puma.new
adapter.start(->(_e) { [200, {}, ["pong"]] }, Shaolin::Server::Config.new(env: { "PORT" => "9292" }))
```

---

## `Shaolin::Server::Timeout` (Falcon cooperative per-request deadline)

```ruby
Shaolin::Server::Timeout.new(app, seconds) # Rack middleware
```

Rack middleware enforcing a per-request deadline on the async (Falcon) adapter. A slow/hung handler
otherwise holds its fiber **and** its checked-out DB connection forever, starving the pool. On expiry
it frees the fiber/connection and returns 503.

```ruby
def call(env)
  task = Async::Task.current?
  return @app.call(env) unless task && @seconds

  task.with_timeout(@seconds) { @app.call(env) }
rescue Async::TimeoutError
  EXPIRED.map(&:dup)
end
```

- **Cooperative**: uses `Async::Task#with_timeout`, which interrupts only at yield points (I/O,
  `sleep` under the reactor). Safe, unlike Ruby's `Timeout` — but a tight CPU loop with no yield is
  **not** interrupted.
- **Inert outside a reactor**: if there is no current `Async::Task` (e.g. under Puma) or `seconds` is
  falsy, it calls the app straight through with no deadline.
- On `Async::TimeoutError` it returns a fresh copy of the frozen `EXPIRED` response:

```ruby
EXPIRED = [503,
           { "content-type" => "application/json", "retry-after" => "1" },
           [%({"error":{"code":"timeout","message":"request timed out"}})]].freeze
```

The `EXPIRED.map(&:dup)` returns a per-request copy so callers can mutate headers/body without
touching the frozen constant.

```ruby
require "async"

Async do
  slow = ->(_e) { sleep 5; [200, {}, ["late"]] }
  Shaolin::Server::Timeout.new(slow, 0.05).call({})  # => [503, {...}, ["{\"error\":{...}}"]]

  fast = ->(_e) { [200, {}, ["ok"]] }
  Shaolin::Server::Timeout.new(fast, 1.0).call({})   # => [200, {}, ["ok"]]
end

# No reactor → inert, runs to completion regardless of the deadline:
Shaolin::Server::Timeout.new(->(_e) { [200, {}, ["ok"]] }, 0.001).call({})  # => [200, {}, ["ok"]]
```

You normally never instantiate `Timeout` yourself — the Falcon adapter wraps the app automatically
when `SHAOLIN_REQUEST_TIMEOUT` (`config.request_timeout`) is set.

---

## Signals & graceful shutdown

| Signal | Handler |
|---|---|
| `SIGTERM` | `Thread.new { adapter.stop(timeout: config.graceful_timeout) }` |
| `SIGINT` | same |

Both traps spawn a thread (trap context is restricted) that calls `adapter.stop`. Falcon raises
`Async::Stop` into the reactor thread to unwind cleanly; Puma calls `@server.stop(true)` to drain
in-flight requests. `graceful_timeout` (default 10s, `SHAOLIN_GRACEFUL_TIMEOUT`) is wired through to
`stop(timeout:)` and matches Cloud Run's ~10s SIGTERM window. Note that neither built-in adapter
currently acts on the `timeout:` value — it bounds intent, not a hard kill.

---

## ENV var reference

| ENV var | Used by | Default | Effect |
|---|---|---|---|
| `HOST` | `Config#host` | `0.0.0.0` | Bind address. |
| `PORT` | `Config#port` | `8080` | Bind port (`Integer`). |
| `SHAOLIN_SERVER` | `Config#adapter` | `falcon` | Adapter: `falcon` or `puma`. |
| `SHAOLIN_GRACEFUL_TIMEOUT` | `Config#graceful_timeout` | `10` | Graceful-stop budget, seconds (`Integer`). |
| `SHAOLIN_REQUEST_TIMEOUT` | `Config#request_timeout` | unset (off) | Per-request deadline, seconds (`Float`); **Falcon only**. |
| `SHAOLIN_ENV` | `banner` | `development` | Reported `env` field. |
| `DB_POOL` | `banner` | `5` | Reported `db_pool` field (`Integer`). |
| `SHAOLIN_WEB_CONCURRENCY` | `banner` | `unbounded` | Reported `web_concurrency` field (display only). |
| `SHAOLIN_LOG` | `Shaolin::Log` | — | Log sink/format for the `server.started` line. |

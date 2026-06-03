# shaolin-server

Web server adapters and process lifecycle for [shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-server-design.md).
Serves the Rack app produced by shaolin-http through a pluggable adapter — **Falcon** (default,
async/fiber-per-request) or **Puma** (opt-in) — with SIGTERM graceful shutdown.

## Run

```ruby
rack_app = Shaolin::Kernel["http.app"]      # from the :http provider
Shaolin::Server.run(rack_app)               # blocks, serving on $PORT
```

`Server.run` builds the configured adapter, installs SIGTERM/SIGINT traps (graceful stop within the
Cloud Run window), and serves until stopped.

## Configuration (12-factor)

| ENV | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | bind port (Cloud Run injects this) |
| `HOST` | `0.0.0.0` | bind host |
| `SHAOLIN_SERVER` | `falcon` | adapter: `falcon` or `puma` |
| `SHAOLIN_GRACEFUL_TIMEOUT` | `10` | drain window (seconds) |

## Adapters

- **Falcon** (default): async, HTTP/1+HTTP/2, fiber-per-request — pairs with AR fiber isolation.
- **Puma**: threaded, the "boring correct" choice. `SHAOLIN_SERVER=puma`.

Both are exercised by live smoke tests (boot → real HTTP request → graceful stop). The kernel and
HTTP layer are server-agnostic; switching adapters is one env var.

See the [design spec](../../docs/superpowers/specs/2026-06-03-shaolin-server-design.md).

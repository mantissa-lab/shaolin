# shaolin-server — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** [shaolin-core](2026-06-03-shaolin-core-design.md), [shaolin-http](2026-06-03-shaolin-http-design.md)
**Sub-project:** 7 of 10 (web server adapters & process lifecycle)

## 1. Purpose

`shaolin-server` serves the Rack app produced by `shaolin-http` (`http.app`) through a **pluggable
server adapter** — **Falcon** (default, async-first) or **Puma** (opt-in) — and owns **process
lifecycle and graceful shutdown** integrated with the kernel, satisfying the Cloud Run / Knative
container contract. The kernel and HTTP layer stay server-agnostic; swapping servers is one config
line.

## 2. Foundation (verified 2026-06-03)

- **Falcon 0.36.x** — multi-process, multi-fiber, built on `async` / `async-http` /
  `async-service`. HTTP/1 + HTTP/2 + TLS native. Programmatic serving via
  `Async::HTTP::Endpoint.parse("http://0.0.0.0:#{port}")` inside an `Async::Service::Configuration`
  (legacy `Falcon::Configuration` removed); `--graceful-stop [timeout]` for draining.
- **Puma 8.x** — `Puma::DSL`: `bind` / `port`, `threads min, max`; `raise_exception_on_sigterm`
  (suppress under k8s/Cloud Run); drains the accept socket on graceful shutdown.

> Exact Falcon `Async::Service` programmatic-launch API and Puma standalone launcher API confirmed
> at planning.

## 3. Adapter port

```ruby
module Shaolin::Server
  class Adapter            # interface
    def start(rack_app, config); end   # bind $PORT, begin serving (blocking)
    def stop(timeout:); end            # graceful drain within timeout, then return
  end
end
```

- **Falcon adapter (default):** parses an endpoint on `0.0.0.0:$PORT`, runs the Rack app under the
  async reactor (fiber-per-request); sets AR fiber isolation (coordinated with
  shaolin-activerecord). Graceful stop drains in-flight fibers within the timeout.
- **Puma adapter (opt-in):** configures the Puma launcher (bind `$PORT`, thread pool), thread
  isolation for AR; graceful shutdown drains the accept socket.

Adapter chosen by config `server.adapter = :falcon | :puma` (default `:falcon`).

## 4. Cloud Run / container contract

- Bind `0.0.0.0:$PORT` (`PORT` env, default **8080**).
- **SIGTERM → graceful shutdown** within the ~10s Cloud Run window: stop accepting, drain in-flight
  requests, then run kernel `shutdown!` (flush Kafka producer, close AR pool, run provider `stop`
  hooks). SIGKILL is the infra backstop.
- The process must be **PID 1** to receive SIGTERM — guaranteed by the Dockerfile's exec-form
  `ENTRYPOINT` (production-runtime spec). For Puma, `raise_exception_on_sigterm = false` so SIGTERM
  is handled as a clean drain, not an exception.
- `GET /healthz` (from shaolin-http) backs liveness/readiness probes.

## 5. Lifecycle orchestration

`shaolin server` boots the app and serves:

1. `Shaolin::App.boot!` — runs providers in dependency order (AR → cqrs → http builds `http.app`
   → kafka producer). Boot failure → log + exit non-zero (no half-started server).
2. Install signal traps (SIGTERM/SIGINT) → trigger graceful stop.
3. `adapter.start(app.container["http.app"], server_config)` — blocking serve.
4. On signal: `adapter.stop(timeout:)` then `Shaolin::App.shutdown!`; exit 0.

The same lifecycle (minus the HTTP adapter) backs the **Kafka worker** entrypoint
(`shaolin karafka server`) — boot providers, run consumers, drain on SIGTERM — so HTTP and worker
images share one lifecycle implementation.

## 6. Configuration

- `PORT` (8080), `HOST` (0.0.0.0), `server.adapter` (:falcon), `WEB_CONCURRENCY`
  (processes/workers), thread/fiber pool sizing, `server.graceful_timeout` (default 10s to match
  Cloud Run). All via ENV (12-factor), typed through shaolin-core config.

## 7. Public API

- `Shaolin::Server.run(app, config)` — boot + serve + lifecycle (used by the CLI).
- `Shaolin::Server::Adapter`, `::Falcon`, `::Puma` — adapter implementations.
- Config namespace `server.*`.

## 8. Error handling

- **Port in use / bind failure** → fail fast, exit non-zero with a clear message.
- **Boot failure** (any provider) → never start serving; exit non-zero.
- **Shutdown timeout exceeded** → log which requests/fibers were still in flight, then force-stop
  (don't hang past the grace window).

## 9. Testing strategy

- Adapter contract specs: boot a trivial Rack app on an ephemeral port, hit it, assert response,
  send SIGTERM, assert graceful drain and clean exit.
- Lifecycle specs with a fake adapter asserting boot→serve→signal→drain→shutdown ordering and
  exit codes.
- Both Falcon and Puma adapters covered by the same shared contract examples.
- RSpec; TDD.

## 10. To verify during planning

- Falcon `Async::Service::Configuration` programmatic launch + graceful-stop timeout API on
  Falcon 0.36.x / Ruby 4.0.
- Puma 8.x standalone launcher (not via `rackup`) and `raise_exception_on_sigterm` behavior.
- Exact AR fiber/thread isolation toggle per adapter (coordinate with shaolin-activerecord).
- Whether to run multi-process (WEB_CONCURRENCY) on Cloud Run (1 container = 1 process is common)
  vs single-process multi-fiber under Falcon — document the recommended default.

# HTTP: controllers, routes, request/response, auth

> Gem `shaolin-http` (`require "shaolin/http"`). Assembles **one Rack app** from every module's
> controllers and publishes it on the kernel as `http.app`. A controller is a thin transport edge:
> validate → dispatch on the command/query bus → render. Controllers hold **no request state** —
> one instance is reused; the action receives a `Request` and returns a `Response` (or a raw Rack
> tuple). Everything is grounded in `gems/shaolin-http/lib/shaolin/http/**`.

The Rack middleware stack the provider builds (outer → inner):

```
RequestLogger → ErrorBoundary → Concurrency(opt) → [app middleware] → RewindableInput → Router
```

So every response gets a request id + access-log line, every exception becomes the JSON error
contract, oversized bodies are capped, and (optionally) in-flight requests are bounded.

---

## 1. Controller

`Shaolin::HTTP::Controller` — base class. Subclass it, declare routes, define one method per action.
Includes `Shaolin::Imports` (so `import("other.thing")` works inside an action).

```ruby
class UsersController < Shaolin::HTTP::Controller
  include Dry::Monads[:result]

  routes do
    get  "/users/:id", :show
    post "/users",     :create, response: UserDTO, auth: :token
  end

  def show(req)   = render_result(query_bus.call(FindUser.new(id: req[:id])))
  def create(req) = render_result(command_bus.call(RegisterUser.new(**req.params)), location: "/users/#{...}")
end
```

### Routes DSL

`self.routes(&block)` — runs the block in a `RouteCollector` and appends to the controller's
`route_set`. Inside the block, one method per HTTP verb:

| Method | Signature |
|---|---|
| `get` / `post` / `put` / `patch` / `delete` | `verb(path, action, response: nil, auth: nil)` |

- `path` — a hanami-router path string; `:name` segments become path params (`/users/:id`).
- `action` — a Symbol naming the instance method called with the `Request`.
- `response:` *(optional, OpenAPI only — does not affect matching)* — a DTO/view class (→ documents
  a 200), `[View]` (200 collection), or a `{ status => View | [View] }` hash. See OpenAPI.
- `auth:` *(optional)* — the Symbol name of an authenticator registered on the `:http` provider.
  Runs before the action; a `nil` identity → 401. Overrides `default_auth`.

```ruby
class Controller::RouteCollector
  def initialize          # @routes = []
  attr_reader :routes     # [{ method:, path:, action:, response:, auth: }, ...]
end
```

- `Controller.route_set` → `Array` of the collected route hashes (memoized per class). Read by the
  Router and OpenAPI generator.

### Auth plane

`self.default_auth(scheme = nil)` — a default authenticator applied to **every** route in the
controller. Called with an arg it sets; with none it reads. A per-route `auth:` wins over it.

```ruby
class AdminController < Shaolin::HTTP::Controller
  default_auth :admin            # guards every route below
  routes do
    get "/admin/stats", :stats   # uses :admin
    get "/admin/raw",   :raw, auth: :super  # overrides → :super
  end
end
```

### Bus / store accessors

Resolved lazily from the kernel (registered by the `:cqrs` provider), so controllers reach the
buses without load-time DI wiring:

| Method | Returns |
|---|---|
| `command_bus` | `Shaolin::Kernel["cqrs.command_bus"]` |
| `query_bus`   | `Shaolin::Kernel["cqrs.query_bus"]` |
| `event_store` | `Shaolin::Kernel["cqrs.event_store"]` |

### Response helpers

All return a `Shaolin::HTTP::Response` (chainable `.cookie` / `.header`); the router renders it.
`JSON_HEADERS = { "content-type" => "application/json" }`.

| Method | Signature | Result |
|---|---|---|
| `json` | `json(data, status: 200, headers: {}, cookies: {})` | JSON body; merges extra `headers`, applies `cookies` map |
| `text` | `text(body, status: 200, headers: {})` | `text/plain; charset=utf-8` |
| `created` | `created(data, location: nil)` | 201 JSON; sets `location` header if given |
| `no_content` | `no_content` | 204, empty body/headers |
| `not_found` | `not_found(message = "not found")` | 404 error contract |
| `bad_request` | `bad_request(message = "bad request")` | 400 error contract |
| `server_error` | `server_error(message = "internal error")` | 500 error contract |
| `unprocessable` | `unprocessable(details)` | 422 `{ error: { code: "validation", details: } }` |

> **That is the complete set.** There is **no** Sinatra/Rails-style `status(code)` builder, no
> `render`, no `head`. To set a status, pass it: `json(data, status: 422)`. To reach the buses use the
> `command_bus` / `query_bus` / `event_store` reader methods above — **not** a `Deps[:...]` locator
> (`Deps` is dry-auto_inject keyword injection, `include Deps["component"]`, a different thing). To
> dispatch another module's command, use `dispatch("mod.command", ...)` (see Modules).

```ruby
def login(_req)
  json({ ok: true }, headers: { "x-trace" => "1" }).cookie(:crm_auth, "tok-123", max_age: 60)
end

def avatar(_req) = text("hi")
def remove(_req) = no_content
```

### `render_result` — the single dry-monads → HTTP edge

```ruby
render_result(result, location: nil)
```

Translates a dry-monads `Result`:

- **Success** → `value!` (or `.success`); if it responds to `to_h` that hash is the body, else
  `{ result: value }`. With `location:` → `created(payload, location:)` (201), else `json(payload)` (200).
- **Failure** → `render_failure`: the failure is `Array()`-coerced into `[code, detail]`:

| Failure code | Status | Error code |
|---|---|---|
| `:not_found` | 404 | `not_found` |
| `:conflict` | 409 | `conflict` |
| *anything else* (`code`) | 422 | `code.to_s` |

```ruby
def show(req)
  return render_result(Failure([:not_found, "no thing #{req[:id]}"])) if req[:id] == "0"
  render_result(Success(id: req[:id]))          # → 200 {"id":"5"}
end
def create(_req) = render_result(Success(id: "new"), location: "/things/new")  # → 201 + Location
```

Private helpers (not for direct use): `render_failure(failure)`, `error_response(status, code, detail)`
— the latter emits `{ error: { code:, message: }.compact }`.

---

## 2. Response builder

`Shaolin::HTTP::Response` — an immutable-per-action response (one fresh object per call → fiber-safe
under Falcon). `attr_reader :status, :headers, :body`.

```ruby
Response.new(status, headers = {}, body = [])
```

| Method | Signature | Notes |
|---|---|---|
| `header` | `header(key, value)` → self | set/overwrite a header |
| `cookie` | `cookie(name, value, path: "/", max_age: nil, http_only: true, same_site: :lax, secure: true, domain: nil)` → self | secure defaults: `HttpOnly` + `SameSite=Lax` + `Secure` |
| `delete_cookie` | `delete_cookie(name, path: "/")` → self | expires it (`Max-Age=0`, `secure: false` so it clears over http too) |
| `cookies` | `cookies(map)` → self | apply a `{ name => "value" \| { value:, **opts } }` hash (the `json(cookies:)` form) |
| `to_rack` (alias `to_a`, `to_ary`) | `[status, headers, body]` | merges cookies into `set-cookie` (a String for one, an Array for many) |

`to_ary` makes the object destructure as a Rack tuple (`status, headers, body = response`), so
back-compat call sites and the controller specs work unchanged.

```ruby
Response.new(200, { "content-type" => "application/json" }, ["{}"])
  .cookie(:crm_auth, "tok", max_age: 60)
  .header("x-foo", "bar")
  .to_rack
# => [200, {"content-type"=>..., "x-foo"=>"bar",
#      "set-cookie"=>"crm_auth=tok; Path=/; Max-Age=60; HttpOnly; Secure; SameSite=Lax"}, ["{}"]]
```

---

## 3. Request

`Shaolin::HTTP::Request` — thin wrapper over the Rack env. `Request.new(env)`. The raw body is read
once and cached; form bodies are parsed once.

| Method | Returns / Notes |
|---|---|
| `params` | hanami `router.params` **merged with** the parsed body, all symbol-keyed (memoized) |
| `[](key)` | `params[key.to_sym]` |
| `env` | `attr_reader` — raw Rack env (e.g. read a value a middleware wrote) |
| `headers` | env entries whose key starts with `HTTP_` |
| `cookies` | request cookies parsed from the `Cookie` header, symbol-keyed (memoized) |
| `body` | raw request body String (rewinds + reads `rack.input` once; `""` if none) |
| `files` | uploaded files from a multipart request (see below); `{}` for non-multipart |

**Body parsing** (`body_params`) by `CONTENT_TYPE`:

- `application/json` → `JSON.parse(body, symbolize_names: true)`; a `JSON::ParserError` → `{}`.
- `multipart/form-data` or `application/x-www-form-urlencoded` → parsed once via `Rack::Request#POST`;
  scalar fields go to params, uploads to `#files`. Empty body → `{}`.

**`#files`** → `{ field => { filename:, type:, tempfile:, bytes: } }` — `bytes` is the read tempfile
contents. Parsing is wrapped in a rescue, so a malformed form yields empty `{}` for both fields/files.

```ruby
req[:name]                       # JSON {"name":"Widget"} → "Widget"
req.cookies[:crm_auth]           # "Cookie: crm_auth=tok" → "tok"
req.files[:image]                # { filename: "logo.png", type: "image/png", bytes: "...", tempfile: #<Tempfile> }
req.env["shaolin.request_id"]    # the request id set by RequestLogger
```

> Multipart requires a rewindable input; the `RewindableInput` middleware guarantees that. For a
> typed cross-cutting channel between middleware and action, prefer `Shaolin::Context` over `env`.

---

## 4. Router

`Shaolin::HTTP::Router` (module) — assembles the Rack app from all module containers' `controllers.*`
components. Built by the `:http` provider; you rarely call it directly.

```ruby
Router.build(containers, middleware: [], openapi: nil, authenticators: {}, max_concurrency: nil)
```

Steps: collect route defs → `detect_conflicts!` → `validate_auth!` → build the hanami router →
wrap middleware (reverse order, so list order = outer→inner) → `RewindableInput` → `Concurrency`
(only if `max_concurrency`) → `ErrorBoundary` → `RequestLogger`.

| Function | Purpose |
|---|---|
| `build(containers, ...)` | assemble the full Rack app (the stack above) |
| `collect_route_defs(containers)` | flatten every controller's `route_set`, attaching `controller:`, `module:`, and resolved `auth:` (route `auth:` or controller `default_auth`) |
| `detect_conflicts!(defs)` | raise `RouteConflictError` if two modules declare the same `[method, path]` |
| `validate_auth!(defs, authenticators)` | raise `BootError` at boot if a route names an unregistered authenticator |
| `build_router(defs, openapi=nil, authenticators={})` | the `Hanami::Router` incl. probes, openapi/swagger, and guarded endpoints |
| `render(result)` | `Response#to_rack` if a `Response`, else pass a raw Rack tuple through |
| `guard(endpoint, authenticator)` | wrap an endpoint: run authenticator; `nil` → 401 `UNAUTHORIZED`, else stash identity in `Shaolin::Context[:identity]` and call the action |
| `readiness_response(_env)` | runs `Shaolin::Health.status` → 200/503 JSON (see Health) |
| `metrics_response(_env)` | `Metrics.render` as `text/plain; version=0.0.4` |

Constants: `LIVENESS` (the `/healthz` lambda), `UNAUTHORIZED` (the frozen 401 tuple), `SWAGGER_HTML`.

**Built-in routes** the router always mounts:

| Route | Purpose |
|---|---|
| `GET /healthz` | liveness — always `200 {"status":"ok"}` |
| `GET /readyz` | readiness — runs `Shaolin::Health` checks; **503** if any dependency is down |
| `GET /metrics` | Prometheus exposition |
| `GET /openapi.json` | OpenAPI 3.1 doc — **only when `openapi` is non-nil** (i.e. `swagger: true`) |
| `GET /swagger` | Swagger UI (CDN assets) pointed at `/openapi.json` — same opt-in |

**Conflicts:** `RouteConflictError` (`< Shaolin::Error`, in `errors.rb`) raised at boot, e.g.
`POST /users defined by both 'a' and 'b'`.

---

## 5. Provider (`:http`)

`Shaolin::HTTP.register_provider!` — registers the `:http` provider; at `start` it builds the Rack
app and registers it as `http.app`. **Register AFTER `:cqrs`** (controllers resolve `cqrs.*` when
instantiated).

```ruby
def self.register_provider!(middleware: [], swagger: false, modules_dir: nil, auth: {}, max_concurrency: nil)
```

| kwarg | Default | Purpose |
|---|---|---|
| `middleware:` | `[]` | list of builders `->(app) { Mw.new(app) }` inserted just before the router (inside the error boundary + logger). Place for app auth / rate limiting / CORS. |
| `swagger:` | `false` | opt-in: generate the OpenAPI doc once at boot and serve `/openapi.json` + `/swagger`. Keep off in production unless you mean to expose docs. |
| `modules_dir:` | `<cwd>/app/modules` | where to scan controllers for DTO linking (OpenAPI) |
| `auth:` | `{}` | `{ scheme_name => ->(env) { identity_or_nil } }` authenticators referenced by route `auth:` / `default_auth` |
| `max_concurrency:` | `ENV["SHAOLIN_WEB_CONCURRENCY"]` (else off) | admission-control cap; wraps the app in `Concurrency` |

```ruby
Shaolin::CQRS.register_provider!          # first
Shaolin::HTTP.register_provider!(
  swagger: true,
  middleware: [
    ->(app) { Shaolin::HTTP::RateLimit.new(app, store: Shaolin::Kernel["redis.store"], limit: 100, window: 60) }
  ],
  auth: { token: ->(env) { env["HTTP_AUTHORIZATION"] == "Bearer s3cret" ? "admin-1" : nil } },
  max_concurrency: 25
)
Shaolin::App.new(root: root).boot!
run Shaolin::Kernel["http.app"]           # config.ru
```

> **ENV:** `SHAOLIN_WEB_CONCURRENCY` (Integer) supplies `max_concurrency` when the kwarg is omitted.

---

## 6. RateLimit middleware

`Shaolin::HTTP::RateLimit` — fixed-window limiter backed by any `Shaolin::Store` (Redis in prod,
`Store::Memory` in tests). Wire via the `middleware:` hook.

```ruby
RateLimit.new(app, store:, limit:, window: 60,
  key: ->(env) { env["HTTP_X_FORWARDED_FOR"]&.split(",")&.first&.strip || env["REMOTE_ADDR"] || "anon" })
```

| kwarg | Default | Purpose |
|---|---|---|
| `store:` | *(required)* | a `Shaolin::Store` with `#increment(key, ttl:)` |
| `limit:` | *(required)* | max requests per window per key |
| `window:` | `60` | window length in seconds |
| `key:` | client IP (`X-Forwarded-For` first hop → `REMOTE_ADDR` → `"anon"`) | derive the bucket key (e.g. a tenant/identity) |

Bucket key is `"ratelimit:#{id}:#{Time.now.to_i / window}"`; the bucket gets `ttl: window * 2` so old
buckets expire. Over `limit`: **429** with `Retry-After: <window>` and body
`{ error: { code: "rate_limited", message: "too many requests" } }`. Within limit, adds
`x-ratelimit-limit` and `x-ratelimit-remaining` headers to the downstream response.

```ruby
mw = RateLimit.new(app, store: Shaolin::Store::Memory.new, limit: 2, window: 60)
mw.call("REMOTE_ADDR" => "1.2.3.4")  # 200 ... 3rd in window → 429
```

---

## 7. Concurrency (admission control / load-shedding)

`Shaolin::HTTP::Concurrency` — bounds in-flight requests so a burst can't oversubscribe the DB pool.
Past the cap it **load-sheds** (immediate 503) rather than queue. Wired automatically when
`max_concurrency` / `SHAOLIN_WEB_CONCURRENCY` is set. Set the cap ≈ `DB_POOL`.

```ruby
Concurrency.new(app, max:)   # max: required
attr_reader :max
def in_flight                # current gauge (Concurrent::AtomicFixnum)
```

On `initialize` it registers itself as `http.concurrency` so `Metrics` can read it. `call` tries to
acquire a `Concurrent::Semaphore` permit; on failure returns `OVERLOADED` (frozen `[503, {retry-after:"1"}, ...]`,
duped per call), code `overloaded`. Otherwise increments the gauge, calls the app, and releases in an
`ensure`.

```ruby
mw = Concurrency.new(app, max: 1)
mw.in_flight          # => 0
# under load past max → [503, {"retry-after"=>"1", ...}, [{"error":{"code":"overloaded",...}}]]
```

---

## 8. RequestLogger

`Shaolin::HTTP::RequestLogger` — outermost middleware. Assigns/propagates a request id and emits one
structured access-log record per request via the unified `Shaolin::Log`.

```ruby
RequestLogger.new(app)
REQUEST_ID_ENV = "shaolin.request_id"
```

- Request id: inbound `X-Request-Id` (`HTTP_X_REQUEST_ID`) or a fresh `SecureRandom.uuid`. Stored in
  `env["shaolin.request_id"]`, pushed into the log context (`Shaolin::Log.with(request_id:)`) so
  downstream commands/events carry it, and echoed back as the `x-request-id` response header.
- Logs `request` with `method`, `path`, `status`, `duration_ms` (monotonic, rounded to 0.1 ms).
  Level: `:error` (≥500), `:warn` (≥400), else `:info`. A handled exception detail comes from
  `env["shaolin.error"]` (stashed by `ErrorBoundary`) or, for a re-raised error, the rescued message.
- **Always clears `Shaolin::Context` in an `ensure`** so identity / project_id set by app middleware
  can't leak to the next request on a reused fiber/thread.

---

## 9. ErrorBoundary

`Shaolin::HTTP::ErrorBoundary` — turns any exception escaping a controller into the standard JSON
error contract `{ "error": { "code", "message" } }` instead of a raw 500 (which could leak a stack
trace).

```ruby
ErrorBoundary.new(app, expose_details: ENV["SHAOLIN_ENV"] != "production")
ERROR_ENV = "shaolin.error"
```

Known exceptions are mapped **by class name** (so this gem needn't depend on ruby_event_store):

| Exception class name | Status | Code |
|---|---|---|
| `RubyEventStore::WrongExpectedEventVersion` | 409 | `conflict` |
| `Shaolin::CQRS::UnregisteredCommand` | 422 | `unprocessable_command` |
| *(anything else)* | 500 | `internal_error` |

For a 500 the message is hidden (`"internal server error"`) unless `expose_details` is true — i.e.
when `SHAOLIN_ENV != "production"` the real message is shown. The exception is stashed in
`env["shaolin.error"]` for the logger.

> **ENV:** `SHAOLIN_ENV` — set to `production` to suppress 500 message detail.

---

## 10. RewindableInput

`Shaolin::HTTP::RewindableInput` — buffers a non-rewindable request body (e.g. Falcon's streaming
`rack.input`) into a rewindable `StringIO`, and caps the body size.

```ruby
RewindableInput.new(app, max_bytes: MAX_BODY_BYTES)
MAX_BODY_BYTES = Integer(ENV.fetch("SHAOLIN_MAX_BODY_BYTES", (1024*1024).to_s))   # 1 MiB
```

- Rejects with **413** (`payload_too_large`) if declared `CONTENT_LENGTH > max`, or if the actual
  body exceeds `max` (reads at most `max + 1` bytes to detect overflow before holding the whole body).
- Rack-test / Puma already give a rewindable `StringIO`, so buffering is a no-op there (it only checks
  size); Falcon's streaming input is read once and replaced with a `StringIO`.

> **ENV:** `SHAOLIN_MAX_BODY_BYTES` — override the 1 MiB cap (bytes).

---

## 11. Metrics

`Shaolin::HTTP::Metrics` (module, `module_function`) — minimal Prometheus text exposition for
`/metrics`. `Metrics.render` → String. Any error → `"shaolin_up 0\n"`.

Series emitted:

| Series | Condition | Meaning |
|---|---|---|
| `shaolin_up 1` | always | liveness |
| `shaolin_db_pool{state="size\|busy\|idle\|waiting"}` | ActiveRecord defined + connected | DB pool utilization (predicts the pool cliff) |
| `shaolin_http_in_flight`, `shaolin_http_concurrency_max` | `http.concurrency` registered | in-flight requests + admission cap |
| `shaolin_outbox_jobs{status="pending\|failed\|done\|dead"}` | `jobs.outbox` registered | outbox depth by status (from `outbox.stats`) |
| `shaolin_outbox_oldest_pending_seconds` | `jobs.outbox` registered | worker lag (`outbox.oldest_pending_age`) |

```ruby
Shaolin::HTTP::Metrics.render
# "# TYPE shaolin_up gauge\nshaolin_up 1\n# TYPE shaolin_http_in_flight gauge\nshaolin_http_in_flight 0\n..."
```

Helpers (also `module_function`): `db_pool(lines)`, `in_flight(lines)`, `outbox(lines)` — each appends
to the `lines` array; `db_pool` swallows its own errors and contributes nothing if AR isn't connected.

---

## 12. OpenAPI generator

`Shaolin::HTTP::OpenAPI` (module, `module_function`) — builds an **OpenAPI 3.1** document from a
**booted** app: paths/verbs/params from each controller `route_set`, request-body schemas from the DTO
an action `validate`s (found by a static Prism scan of the controller file), plus the standard
error schema. Served by the `:http` provider when `swagger: true`; the CLI's `shaolin openapi` reuses it.

```ruby
OpenAPI.generate(containers, modules_dir, title: "API")
# => { "openapi"=>"3.1.0", "info"=>{...}, "paths"=>{...}, "components"=>{ "schemas"=>{...} } }
```

| Function | Purpose |
|---|---|
| `generate(containers, modules_dir, title: "API")` | the full document; always registers an `Error` schema |
| `scan_action_dtos(modules_dir, module_name)` | Prism-scan `controllers/*.rb` → `{ "action" => "SomeDTO" }` |
| `operation(route, action_dtos, namespace, module_name, schemas)` | one operation object (operationId `"<Namespace>_<action>"`, tag = module) |
| `build_responses(spec, schemas)` | turn route `response:` into the `responses` object |
| `schema_for(view, schemas)` | `View`→`$ref`; `[View]`→array of `$ref`; nil otherwise |
| `register_dto` / `register_schema(klass, schemas)` | register a class's JSON Schema (via dry-schema `:json_schema`) as a named component, returning its name |
| `resolve(const_name, namespace)` | constant lookup (top-level, then `Namespace::Const`) |
| `openapi_path(path)` | `"/users/:id"` → `"/users/{id}"` |
| `path_params(path)` | `:name` segments → required string path params |
| `error_response(desc)` | a `$ref: #/components/schemas/Error` response |

- Request bodies are linked only for `post`/`put`/`patch` when the scanned DTO const matches `/DTO\z/i`;
  doing so also adds a `422` validation response.
- A view is anything with `.schema.json_schema` (e.g. a `Shaolin::DTO`); `$schema` is stripped and keys
  stringified. `register_schema` swallows errors → `nil` (route is left with a generic 200).
- `class ActionDTOScanner < Prism::Visitor` collects `def <name> ... <Const>.validate(...)` →
  `{ name => const }`.

```ruby
doc = Shaolin::HTTP::OpenAPI.generate(Shaolin::Kernel["kernel.containers"], "app/modules", title: "CRM")
doc["paths"]["/users/{id}"]["get"]   # => { "operationId"=>"Users_show", "tags"=>["users"], "responses"=>{...} }
```

---

## 13. Health / readiness endpoints

The probes are wired by the Router but back by `Shaolin::Health` (shaolin-core):

- `GET /healthz` — liveness, **always 200** `{"status":"ok"}`. No checks; use for "process is up".
- `GET /readyz` — readiness: runs every registered `Shaolin::Health` check via `Shaolin::Health.status`
  → `[ok, detail]`. Response is `{ status: "ok"|"unavailable", checks: { name => bool, ... } }` with
  **200** when all pass, **503** if any fails. Use for load-balancer/Knative readiness gating.

```ruby
Shaolin::Health.register("database") { ActiveRecord::Base.connection.active? }
# GET /readyz → 200 {"status":"ok","checks":{"database":true}}   (503 if the block returns false)
```

---

## Errors & ENV summary

| Error | Raised when |
|---|---|
| `Shaolin::HTTP::RouteConflictError` (`< Shaolin::Error`) | two modules declare the same verb+path (boot) |
| `Shaolin::BootError` (shaolin-core) | a route names an authenticator not in `auth:` (boot) |

| ENV var | Used by | Effect |
|---|---|---|
| `SHAOLIN_WEB_CONCURRENCY` | provider | default `max_concurrency` (admission cap) |
| `SHAOLIN_MAX_BODY_BYTES` | `RewindableInput` | body-size cap (default 1 MiB) |
| `SHAOLIN_ENV` | `ErrorBoundary` | `production` hides 500 messages |

| HTTP status | Source |
|---|---|
| 401 `unauthorized` | `Router.guard` (authenticator returned nil) |
| 413 `payload_too_large` | `RewindableInput` |
| 429 `rate_limited` | `RateLimit` |
| 503 `overloaded` | `Concurrency` |
| 503 readiness | `/readyz` when a health check fails |
| 409 `conflict` / 422 `unprocessable_command` / 500 `internal_error` | `ErrorBoundary` |

## WebSocket (`Shaolin::HTTP::WebSocket`)

A first-class, **domain-agnostic** WebSocket on `async-websocket` (Falcon-native). Both directions,
same `Socket` API (`on_open` / `on_message(|data, socket|)` / `on_close` / `on_error` + `send` /
`close`). Frames arrive as raw `String`s (text or binary) — **not** tied to LLM/realtime or any schema.
Falcon only (async reactor); under Puma run a dedicated WS server.

**Server** — upgrade an inbound request from any controller action:

```ruby
class ChatController < Shaolin::HTTP::Controller
  routes { get "/ws/chat/:room", :chat }   # a normal route

  def chat(req)
    ws(req) do |socket|                     # 400 automatically if not a WS upgrade
      socket.on_open    { socket.send(%({"hello":"#{req[:room]}"})) }
      socket.on_message { |data, s| s.send(echo(data)) }          # text
      socket.on_message { |bytes, s| forward_audio(bytes) }        # or binary frames
      socket.on_close   { cleanup }
    end
  end
end
```

**Client** — connect OUT to **any** WebSocket server (Asterisk ARI, a third-party feed, another
shaolin service), same Socket API, inside an Async reactor:

```ruby
Shaolin::HTTP::WebSocket.connect("wss://asterisk/ari/events",
  headers: { "authorization" => "Bearer #{token}" }) do |socket|
  socket.on_message { |event| handle(event) }
  socket.send(%({"type":"subscribe"}))
end
```

| Method | Purpose |
|---|---|
| `WebSocket.upgrade?(env)` | is this request a WS upgrade? |
| `WebSocket.open(env) { \|socket\| }` | server: accept + run (the `ws(req)` controller helper wraps this) |
| `WebSocket.connect(url, headers:) { \|socket\| }` | client: connect to any WS server + run |
| `Socket#on_open/on_message/on_close/on_error`, `#send(data, binary: false)`, `#close` | the JS-like handler API |

> The LLM **realtime** transport (`Shaolin::LLM::Realtime::WebSocketTransport`) is just **one consumer**
> of this — a thin JSON-framing adapter for the OpenAI Realtime contract. The WebSocket itself is general.

# shaolin-http — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** [shaolin-core](2026-06-03-shaolin-core-design.md), [shaolin-cqrs](2026-06-03-shaolin-cqrs-design.md)
**Sub-project:** 4 of 10 (HTTP transport adapter)

## 1. Purpose

`shaolin-http` is the HTTP transport adapter. It maps HTTP requests onto the CQRS core: **writes
become commands** dispatched on the command bus, **reads become queries** on the query bus. It
owns routing conventions, the base controller, request/response lifecycle, JSON serialization, and
the translation of `dry-monads` results into HTTP status codes. It is one of several
interchangeable transports — it adds no business logic of its own.

## 2. Foundation (verified 2026-06-03)

- **hanami-router 2.x** — standalone Ruby/Rack HTTP router. `Hanami::Router.new do … end` is a Rack
  app. Supports **Rack 2 and 3** (Hanami 2.3+, Nov 2025). Params via `env["router.params"]`;
  endpoints can be lambdas, rack apps, mounted apps, scopes. `router.recognize` for introspection.
- Works under **Falcon** (Rack 3, async-first) — actions look synchronous and cooperate via the
  fiber scheduler; one fiber per request.

> Exact hanami-router 2.x mounting/scope API and Rack 3 behavior under Falcon confirmed at planning.

## 3. Controller convention

Each module declares its HTTP surface in `controllers/`:

```ruby
class UsersController < Shaolin::HTTP::Controller
  include Deps["cqrs.command_bus", "cqrs.query_bus"]

  routes do
    post   "/users",      :create
    get    "/users/:id",  :show
  end

  def create(req)
    dto = RegisterUserDTO.validate(req.params)        # boundary validation
    return unprocessable(dto.errors) if dto.failure?
    result = command_bus.(RegisterUser.new(dto.to_h)) # write path
    render_result(result, created: "/users/#{result.value!}")
  end

  def show(req)
    result = query_bus.(FindUser.new(id: req.params[:id]))  # read path
    render_result(result)
  end
end
```

- The `routes` DSL declares method + path + action; shaolin-http compiles these into hanami-router
  routes scoped to the module and mounts them on the app router.
- Controllers are resolved from the **module container** (DI via `Deps`), so dependencies (buses,
  services) are injected, never globally referenced.
- A controller **only** orchestrates: validate → dispatch → render. No domain logic.

## 4. Request lifecycle

`Rack env (Falcon) → app router (hanami-router) → matched module route → controller action
(resolved from module container, one fiber per request) → DTO validation → command_bus / query_bus
→ dry-monads Result → render (JSON) → Rack response.`

## 5. Routing assembly

- shaolin-http builds one root `Hanami::Router`. For each module (in registry order) it mounts that
  module's declared controller routes. Path collisions across modules are detected at boot and
  raise (fail fast), preserving module isolation at the URL layer.
- A health endpoint (`GET /healthz`) is provided for Cloud Run/Knative probes.

## 6. Result → HTTP translation

`render_result` maps `dry-monads` results at the edge (the single place transport codes live):

| Result | HTTP |
|---|---|
| `Success(value)` | 200 (or 201 with `created:` location) |
| `Failure([:validation, errors])` / DTO failure | 422 + error body |
| `Failure([:not_found, …])` | 404 |
| `Failure([:conflict, …])` (optimistic concurrency / invariant) | 409 |
| `Failure([:unprocessable, …])` | 422 |
| unexpected exception | 500 (logged; body sanitized) |

Error bodies follow one JSON shape (`{ "error": { "code", "message", "details" } }`).

## 7. Serialization

- JSON by default. A thin serializer convention turns read-model objects / value objects into JSON
  (no leaking of AR internals). Per-module serializers live alongside controllers; a sensible
  default serializes public attributes.
- Content negotiation is minimal in cycle 1 (JSON only); pluggable later.

## 8. Async behavior (Falcon-first)

- Controllers contain no `await`-style code; blocking calls (DB via AR, downstream HTTP) cooperate
  through the fiber scheduler. One connection per request-fiber (see shaolin-activerecord).
- Long/streaming responses are out of scope for cycle 1.

## 9. Kernel integration (provider)

```ruby
Shaolin.register_provider(:http) do
  start do
    # build the root Hanami::Router; for each module, compile its controllers' routes
    # and mount them; register the Rack app as "http.app" in the container.
  end
end
```

`shaolin-server` consumes `http.app` as the Rack application to serve. shaolin-http does not start
a server itself — it only produces a Rack app, keeping server choice (Falcon/Puma) separate.

## 10. Public API

- `Shaolin::HTTP::Controller` — base controller: `routes` DSL, `render_result`, `unprocessable`,
  `not_found`, helpers; `Deps` injection.
- `Shaolin::HTTP::Request` — thin wrapper over Rack env exposing `params` (merged
  `router.params` + body + query), headers, body.
- Container key: `http.app` (the mounted Rack application).

## 11. Error handling

- **Route collision** across modules → boot-time `Shaolin::HTTP::RouteConflictError` naming both
  modules and the path.
- **Unhandled exception in an action** → 500, logged with request id; never leaks internals.
- **Missing command/query handler** → surfaced at boot by shaolin-cqrs wiring, not at request time.

## 12. Testing strategy

- `rack-test` against the mounted app for request specs (status, body shape).
- Controller unit tests with stubbed buses asserting the validate→dispatch→render orchestration.
- Result-translation table covered by focused specs (each row).
- RSpec; TDD.

## 13. To verify during planning

- hanami-router 2.x exact API for mounting/scoping module route sets and reading params under Rack 3.
- Behavior under Falcon (Rack 3) — confirm params + body parsing and fiber-per-request.
- Whether the `routes` DSL compiles to hanami-router at boot or wraps a per-module sub-router
  mounted via `mount`.
- Request body parsing (JSON) middleware choice compatible with Rack 3 / Falcon.

# shaolin-http

HTTP transport for [shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-http-design.md), on
`hanami-router` + Rack 3. Controllers map requests to commands/queries; `dry-monads` results
translate to HTTP at one edge. One Rack app is assembled from every module's controllers.

## Controller

```ruby
module Users
  module Controllers
    class UsersController < Shaolin::HTTP::Controller
      routes do
        get  "/users/:id", :show
        post "/users",     :create
      end

      def show(req)
        render_result(query_bus.call(FindUser.new(id: req[:id])))
      end

      def create(req)
        dto = RegisterUserDTO.validate(req.params)
        return unprocessable(dto.errors) if dto.failure?

        result = command_bus.call(RegisterUser.new(dto.to_h))
        render_result(result, location: "/users/#{result.value!}")
      end
    end
  end
end
```

- `routes do … end` declares verb + path + action.
- `command_bus` / `query_bus` / `event_store` are resolved lazily from the kernel (registered by
  `:cqrs`) — no load-time DI wiring needed.
- A controller only orchestrates: validate → dispatch → render. No domain logic.

## Result → HTTP

`render_result` maps a `dry-monads` result at the single edge transport codes live:

| Result | HTTP |
|---|---|
| `Success(v)` | 200 (or 201 with `location:`) |
| `Failure([:not_found, …])` | 404 |
| `Failure([:conflict, …])` | 409 |
| any other `Failure` / DTO failure | 422 |

Error bodies use `{ "error": { "code", "message" } }`.

## Assembly

The `:http` provider (`Shaolin::HTTP.register_provider!`, registered **after** `:cqrs`) builds one
`Hanami::Router` from every module's `controllers.*`, adds `GET /healthz`, and registers it as
`http.app`. Verb+path collisions across modules fail fast (`RouteConflictError`).

See the [design spec](../../docs/superpowers/specs/2026-06-03-shaolin-http-design.md).

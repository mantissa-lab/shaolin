# DTO & validation

`shaolin-dto` is the **boundary** layer. It draws one line: untrusted input gets shaped, typed,
coerced, and rejected by a **DTO**; once it passes, you construct an immutable, typed **ValueObject**
(the command/query) that the rest of the system trusts. Built on `dry-validation`, `dry-struct`, and
`dry-types`.

```ruby
require "shaolin/dto"   # loads DTO, Types, ValueObject (Result is nested in DTO)
```

| Class / Module | Purpose |
|---|---|
| `Shaolin::DTO` | Boundary validation contract (subclass of `Dry::Validation::Contract`). `.validate(input)` → `Result`. |
| `Shaolin::DTO::Result` | Stable wrapper over a dry-validation result: `success?`/`failure?`/`to_h`/`errors`. |
| `Shaolin::Types` | Shared dry-types module (`include Dry.Types()`) for `attribute` declarations. |
| `Shaolin::ValueObject` | Immutable, typed value-object base (subclass of `Dry::Struct`) for commands/queries. |
| `Shaolin::DTO_VERSION` | `"0.1.0"` constant. |

The dependency wall (from the gemspec): `dry-validation ~> 1.10`, `dry-struct ~> 1.6`,
`dry-types ~> 1.7`, plus `shaolin-core`. Ruby `>= 4.0.0`.

---

## `Shaolin::DTO`

Subclass it and declare a schema block. Because it **is** a `Dry::Validation::Contract`, the full
dry-validation DSL is available unchanged: schema macros (`json`/`params`/`schema`), `rule`, `option`,
etc. shaolin adds exactly two things — the lenient `json.float` type and the `.validate` → `Result`
wrapper.

```ruby
class RegisterUserDTO < Shaolin::DTO
  json do
    required(:email).filled(:string)
    required(:name).filled(:string)
    optional(:age).maybe(:integer)
  end

  rule(:email) do
    key.failure("has invalid format") unless value.include?("@")
  end
end
```

### Schema blocks: `json` vs `params` vs `schema`

These are the standard dry-validation schema macros (not defined by shaolin); pick by where the input
comes from.

| Macro | Coercion behaviour | Use for |
|---|---|---|
| `json { ... }` | JSON-aware coercion (strings stay strings; numbers stay numbers) | JSON request bodies — the shaolin default |
| `params { ... }` | HTTP-param coercion (`"5"` → `5`, `"true"` → `true`) | `x-www-form-urlencoded` / query strings |
| `schema { ... }` | No type coercion at all | already-typed Ruby hashes |

Inside any of them you use `required(:k)` / `optional(:k)` followed by predicates: `.filled(:string)`,
`.maybe(:integer)`, `.value(:array)`, `.filled(:json_float)`, etc. Nested schemas via
`.hash do ... end` and `.array(:hash) do ... end` work as in dry-validation.

### `rule` — stateless cross-field / format checks

`rule` runs **after** the schema passes, for format/relationship checks that don't need external state.
Domain invariants that need state (uniqueness, "already shipped") belong in the aggregate
(`shaolin-cqrs`), **never** in a DTO.

```ruby
class DateRangeDTO < Shaolin::DTO
  json do
    required(:from).filled(:string)
    required(:to).filled(:string)
  end

  rule(:to) do
    key.failure("must be after from") if value < values[:from]
  end
end
```

### `.validate(input)` → `Shaolin::DTO::Result`

```ruby
def self.validate(input)   # input: Hash (string OR symbol keys both accepted)
  Result.new(new.call(input))
end
```

One-line purpose: validate an untrusted hash, returning a stable `Result` so transports never touch
dry-validation internals.

```ruby
RegisterUserDTO.validate("email" => "a@b.c", "name" => "Jane")
# => #<Shaolin::DTO::Result>  (success?: true, to_h: {email: "a@b.c", name: "Jane"})

RegisterUserDTO.validate(email: "bad", name: "")
# => failure?: true, errors: { email: ["has invalid format"], name: ["must be filled"] }
```

- Accepts **string- or symbol-keyed** input; `to_h` always returns **symbol** keys.
- `optional` keys absent from the input are simply omitted from `to_h` (not set to `nil`).

---

## `Shaolin::DTO::Result`

A frozen-interface wrapper. The transport (HTTP controller, RabbitMQ consumer) only ever sees these
four methods, so swapping the validation engine never ripples outward.

| Method | Signature | Returns |
|---|---|---|
| `#success?` | `() -> Boolean` | true when validation passed |
| `#failure?` | `() -> Boolean` | true when any field failed |
| `#to_h` | `() -> Hash` | coerced, symbol-keyed attributes (on success) |
| `#errors` | `() -> Hash` | per-field error hash, e.g. `{ email: ["has invalid format"] }` |

```ruby
result = RegisterUserDTO.validate(req.params)
return unprocessable(result.errors) if result.failure?     # → HTTP 422
command_bus.call(RegisterUser.new(**result.to_h))
```

Gotchas:
- `to_h` on a **failed** result returns whatever dry-validation produced (partial/empty); guard on
  `failure?` first.
- `errors` is `@result.errors.to_h` — a plain hash of `field => [messages]`. Nested fields come back
  as nested hashes (dry-validation's default), not dotted keys.

---

## Numeric coercion: `json.float` / `:json_float`

The base class registers one extra type on **every** DTO:

```ruby
config.types.register("json.float", Dry::Types["coercible.float"])
```

Purpose: accept a JSON integer where a float is declared — JSON `5` for a price field becomes `5.0`
instead of failing `"must be a float"`. Reference it in a schema as the predicate `:json_float`
(dry-validation maps the `:json_float` symbol to the registered `"json.float"` type — dot becomes
underscore).

```ruby
class PriceDTO < Shaolin::DTO
  json do
    required(:name).filled(:string)
    required(:amount).filled(:json_float)
  end
end

PriceDTO.validate(name: "x", amount: 5).to_h    # => { name: "x", amount: 5.0 }  (int coerced)
```

Behaviour / gotchas:
- Inherited by every subclass (registered on the `Shaolin::DTO` base config).
- **Only `:json_float` coerces** int→float. A plain `:float` predicate under a `json` block also
  tolerates an integer in practice (JSON coercion), but `:json_float` is the explicit, intent-revealing
  declaration — prefer it for money/amount fields.
- `:string` stays **strict** — a number is *not* coerced to a string (`amount: ...` with `name: 5`
  fails). Coercion leniency is opt-in per field, not global.
- A genuinely non-numeric value still fails: `amount: "nope"` → `failure?`.

---

## `Shaolin::Types`

```ruby
module Shaolin
  module Types
    include Dry.Types()
  end
end
```

A shared dry-types namespace so value objects (and any typed code) reference one consistent type set.
Use it to type `ValueObject` attributes. Common members (all from dry-types):

| Type | Notes |
|---|---|
| `Shaolin::Types::String` | strict string |
| `Shaolin::Types::Integer` | strict integer |
| `Shaolin::Types::Float` | strict float |
| `Shaolin::Types::Bool` | strict boolean |
| `Shaolin::Types::Hash` / `::Array` | container types |
| `Shaolin::Types::Coercible::Integer` | coerce on construction |
| `Shaolin::Types::String.optional` | allows `nil` |
| `Shaolin::Types::Integer.default(0)` | default value |

---

## `Shaolin::ValueObject`

```ruby
class ValueObject < Dry::Struct
  transform_keys(&:to_sym)
end
```

One-line purpose: immutable, typed value object for **commands and queries** — the trusted intent you
build from a validated DTO hash. `transform_keys(&:to_sym)` means it accepts string- or symbol-keyed
input interchangeably (so `Cmd.new(**dto.to_h)` and `Cmd.new(JSON.parse(body))` both work).

```ruby
class Money < Shaolin::ValueObject
  attribute :amount,   Shaolin::Types::Integer
  attribute :currency, Shaolin::Types::String
end

Money.new(amount: 100, currency: "USD")   # => #<Money amount=100 currency="USD">
Money.new(amount: "nope", currency: "USD") # raises Dry::Struct::Error
```

The full `Dry::Struct` API applies: `attribute`, `attribute?` (optional), `attributes` (the hash),
`with(...)` (copy-on-write), value equality. Instances are **immutable**.

Idiomatic boundary handoff:

```ruby
result = RegisterUserDTO.validate(req.params)
return unprocessable(result.errors) if result.failure?
command_bus.call(RegisterUser.new(**result.to_h))   # DTO (untrusted) → ValueObject (trusted)
```

Where the line is:
- **Shape / types / coercion / stateless format rules** → DTO.
- **Domain invariants needing state** (uniqueness, state machine) → aggregate, not the DTO.

---

## How DTOs feed OpenAPI

`shaolin openapi` (CLI) and the `:http` provider's `/openapi.json` + `/swagger` both call
`Shaolin::HTTP::OpenAPI.generate` against a **booted** app. DTO schemas become request-body schemas
with no extra annotation.

```ruby
Shaolin::HTTP::OpenAPI.generate(containers, modules_dir, title: "API")
# => { "openapi" => "3.1.0", "info" => {...}, "paths" => {...},
#      "components" => { "schemas" => { "Error" => {...}, "CreatePostDTO" => {...} } } }
```

The pipeline:

1. **Path + method** come from each controller's `route_set`. Path params (`:id`) become
   `{id}` with a `string` schema.
2. **Request body** — `OpenAPI.scan_action_dtos` does a **static Prism parse** of each
   `controllers/*.rb`, mapping `def <action> ... <Const>.validate(...)` → the DTO const (the const must
   end in `DTO`, case-insensitive). For `post`/`put`/`patch` routes the matched DTO's JSON Schema is
   registered as a component and `$ref`'d under `application/json`; a `422` response (the `Error`
   schema) is added automatically.
3. **Schema extraction** — the generator loads `Dry::Schema.load_extensions(:json_schema)` and calls
   `klass.schema.json_schema` on the DTO, then JSON round-trips it to string keys and strips `$schema`.
   Any class responding to `:schema` (i.e. answering `.schema.json_schema`) qualifies — a `Shaolin::DTO`
   does, so it can also be used as a `response:` view.
4. **Responses** — the route's `response:` option drives them: `View` → `200` with a `$ref`;
   `[View]` → `200` array of that schema; `{ status => View }` → documents several; `nil` → generic
   `200 OK`. The `Error` component (`{ error: { code, message } }`) backs every error response.

Gotchas:
- Linkage is a **static scan**, not runtime: the DTO must be referenced literally as
  `SomeDTO.validate(...)` inside the action method body, and the const name must end in `DTO`.
- Only `post`/`put`/`patch` get a `requestBody`; `get`/`delete` DTOs are ignored for the body.
- `register_schema` swallows errors (`rescue StandardError → nil`): a DTO whose `json_schema` can't be
  built is silently dropped from the document rather than crashing generation.
- Const resolution tries the bare name, then `Namespace::Const` (controller's top namespace) — so
  `DTO::CreatePostDTO` nested under the module namespace resolves.

In production (`SHAOLIN_ENV=production`) Swagger UI / `/openapi.json` are **off**; generate the document
as a build artifact via `shaolin openapi [--out FILE]`.

---

## End-to-end (the boundary in one place)

```ruby
# app/modules/posts/dto/create_post_dto.rb
module Posts
  module DTO
    class CreatePostDTO < Shaolin::DTO
      json do
        required(:title).filled(:string)
        optional(:price).filled(:json_float)
      end
    end
  end
end

# app/modules/posts/commands/create_post.rb
module Posts
  module Commands
    class CreatePost < Shaolin::ValueObject
      attribute :title, Shaolin::Types::String
      attribute? :price, Shaolin::Types::Float
    end
  end
end

# controller action
def create(req)
  result = DTO::CreatePostDTO.validate(req.params)        # untrusted in
  return unprocessable(result.errors) if result.failure?  # → 422 + per-field errors
  render_result(command_bus.call(Commands::CreatePost.new(**result.to_h)))  # trusted intent
end
```

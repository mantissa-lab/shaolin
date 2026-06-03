# shaolin-dto — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** [shaolin-core](2026-06-03-shaolin-core-design.md); consumed by [shaolin-http](2026-06-03-shaolin-http-design.md) and [shaolin-cqrs](2026-06-03-shaolin-cqrs-design.md)
**Sub-project:** 5 of 10 (boundary validation & typed value objects)

> **Packaging note:** this is a thin concern. It may ship as its own gem `shaolin-dto` or fold
> into `shaolin-cqrs`. Decided here: **separate gem**, because both shaolin-http (input boundary)
> and shaolin-cqrs (command/query contracts) depend on it, and a module's `dto/` is part of its
> agent-ownable surface.

## 1. Purpose

`shaolin-dto` provides **boundary validation** and **typed value objects**. It answers one
question at the edge of a module: *is this raw input well-formed enough to become a command or a
query?* Heavy domain invariants stay in aggregates (shaolin-cqrs); DTOs guard shape, types, and
simple format rules — nothing that requires loading domain state.

## 2. Foundation (verified 2026-06-03)

- **dry-validation** `Dry::Validation::Contract`: `params { required(:k).filled(:string) }` (HTTP
  coercion: string→int), `json { … }` (JSON-native coercion), `schema { … }` (no coercion);
  `rule(:k) { key.failure("…") }` and `base.failure("…")` for cross-field; `contract.call(input)`
  → Result with `.success?`, `.failure?`, `.to_h`, `.errors.to_h`.
- **dry-struct** + **dry-types** for immutable, typed value objects (commands/queries).

## 3. DTO convention

A DTO is a contract that validates raw input and yields a clean attribute hash:

```ruby
class RegisterUserDTO < Shaolin::DTO
  json do                                   # JSON bodies (Falcon)
    required(:email).filled(:string)
    required(:name).filled(:string)
    optional(:age).maybe(:integer)
  end

  rule(:email) do
    key.failure("has invalid format") unless value.match?(EMAIL_RE)
  end
end

result = RegisterUserDTO.validate(req.params)  # => Shaolin::DTO::Result
result.success?   # bool
result.to_h       # coerced attributes
result.errors     # { email: ["has invalid format"] } — feeds HTTP 422 body
```

- `Shaolin::DTO` is a thin base over `Dry::Validation::Contract` adding `.validate(input)`
  (class-level convenience) returning a `Shaolin::DTO::Result` with a stable interface
  (`success?`/`failure?`/`to_h`/`errors`) so transports don't couple to dry-validation internals.
- DTOs live in a module's `dto/` folder; they are part of the module's public contract.

## 4. Two validation layers (and where the line is)

| Layer | Belongs in | Example |
|---|---|---|
| Shape & types & coercion | DTO (`json`/`params` schema) | "email is a required string" |
| Stateless format rules | DTO (`rule`) | "email matches a regex", "qty > 0" |
| Domain invariants needing state | **Aggregate** (shaolin-cqrs) | "email is unique", "order not already shipped" |

This keeps DTOs fast and stateless (no DB), and keeps real business rules in the event-sourced
aggregate where they can see history.

## 5. Commands & queries as typed value objects

- Commands/queries are **dry-struct** value objects (immutable, typed): the validated DTO hash is
  used to construct them (`RegisterUser.new(result.to_h)`).
- `shaolin-cqrs` exposes `Shaolin::CQRS::Command`/`::Query` bases built on dry-struct; this gem
  provides the dry-struct/dry-types wiring they share.
- Separation: **DTO = untrusted input contract; Command = trusted typed intent.** The controller
  validates the DTO, then builds the Command.

## 6. Integration points

- **shaolin-http:** controller calls `SomeDTO.validate(req.params)`; on failure renders 422 from
  `result.errors`; on success builds the command from `result.to_h`.
- **shaolin-cqrs:** command/query structs typed via this gem; an optional command-level contract
  can re-validate at the bus boundary for non-HTTP transports (e.g. Kafka inbound).
- **Kafka inbound (shaolin-kafka):** the consumer validates the message with the same DTO before
  building a command — identical guarantee regardless of transport.

## 7. Public API

- `Shaolin::DTO` — base contract; `.validate(input)` → `Shaolin::DTO::Result`.
- `Shaolin::DTO::Result` — `success?`, `failure?`, `to_h`, `errors` (hash).
- `Shaolin::Types` — shared dry-types module for value objects.
- Error hash shape aligns with shaolin-http's `{ error: { code: "validation", details: {…} } }`.

## 8. Error handling

- A DTO never raises on invalid input — it returns a failure result. Raising is reserved for
  programmer error (e.g. malformed contract definition), surfaced at boot/load.
- Coercion failures (e.g. non-integer where integer expected) are reported as field errors, not
  exceptions.

## 9. Testing strategy

- Table-driven contract specs: valid input → `success?` + expected `to_h`; invalid → expected
  `errors`. One row per rule and per coercion.
- Round-trip: validated `to_h` constructs the corresponding command struct without error.
- RSpec; TDD.

## 10. To verify during planning

- dry-validation / dry-schema / dry-struct / dry-types 1.x exact versions and Ruby 4.0 compat.
- `json` vs `params` coercion choice for Falcon JSON bodies (confirm Falcon delivers parsed JSON
  or whether a parsing middleware feeds string params → use `params`).
- Whether to expose dry-validation's full rule DSL or a curated subset as the shaolin DTO surface.

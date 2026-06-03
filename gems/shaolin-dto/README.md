# shaolin-dto

Boundary validation and typed value objects for [shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-dto-design.md),
built on `dry-validation`, `dry-struct`, and `dry-types`.

## DTO — untrusted input contract

```ruby
class RegisterUserDTO < Shaolin::DTO
  json do
    required(:email).filled(:string)
    required(:name).filled(:string)
    optional(:age).maybe(:integer)
  end

  rule(:email) { key.failure("has invalid format") unless value.include?("@") }
end

result = RegisterUserDTO.validate(request_params)
result.success?  # => true/false
result.to_h      # => coerced attributes
result.errors    # => { email: ["has invalid format"], ... }  (feeds HTTP 422)
```

`validate` returns a `Shaolin::DTO::Result` with a stable interface (`success?`/`failure?`/`to_h`/
`errors`) so transports never couple to dry-validation internals.

## ValueObject — trusted typed intent

```ruby
class RegisterUser < Shaolin::ValueObject
  attribute :email, Shaolin::Types::String
  attribute :name,  Shaolin::Types::String
end

RegisterUser.new(RegisterUserDTO.validate(params).to_h)
```

## Where the line is

- **Shape / types / coercion** and stateless format rules → DTO.
- **Domain invariants that need state** (uniqueness, "already shipped") → the aggregate
  (shaolin-cqrs), never the DTO.

DTO = untrusted input contract. ValueObject = trusted, typed intent. The controller validates the
DTO, then constructs the command/query value object from `to_h`.

See the [design spec](../../docs/superpowers/specs/2026-06-03-shaolin-dto-design.md).

# shaolin-cqrs

CQRS + Event Sourcing building blocks for [shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-cqrs-design.md),
layered on [ruby_event_store](https://railseventstore.org), `aggregate_root`, and
`arkency-command_bus`. Transport-agnostic: HTTP and Kafka adapters only ever produce commands or
carry events.

## Building blocks

| Concept | API |
|---|---|
| Stream name | `Shaolin::CQRS.stream_name(Users::User, id)` → `"Users::User$<id>"` |
| Aggregate | `include Shaolin::CQRS::Aggregate` → `apply(event)` + `on EventClass do |e| … end`, plus `#id` |
| Command bus | `Shaolin::CQRS::CommandBus#register(CmdClass, handler)` / `#call(cmd)` |
| Query bus | `Shaolin::CQRS::QueryBus#register(QueryClass, handler)` / `#call(query)` |
| Event store | `Shaolin::CQRS::EventStore.in_memory` / `.build(repository:)` |
| Aggregate repository | `#unit_of_work(aggregate) { |a| … }` / `#load(klass, id)` |

## Aggregate

```ruby
class User
  include Shaolin::CQRS::Aggregate

  def initialize(id)
    super(id)
    @registered = false
  end

  def register(email:) = apply(UserRegistered.new(data: { id: id, email: email }))

  on UserRegistered do |event|
    @registered = true
  end
end
```

## Command handler

```ruby
class RegisterUserHandler
  include Deps["cqrs.aggregate_repository"]

  def call(cmd)
    cqrs_aggregate_repository.unit_of_work(User.new(cmd.id)) do |user|
      user.register(email: cmd.email)
    end
    Dry::Monads::Success(cmd.id)
  end
end
```

## Kernel integration

The `:cqrs` provider (enabled via `Shaolin::CQRS.register_provider!`) publishes
`cqrs.command_bus`, `cqrs.query_bus`, `cqrs.event_store`, and `cqrs.aggregate_repository` into the
shared kernel container, so any module resolves them through `Deps[...]`. The event-store backend
is injected by `shaolin-activerecord`; absent one, an in-memory store is used (dev/test).

See the [design spec](../../docs/superpowers/specs/2026-06-03-shaolin-cqrs-design.md).

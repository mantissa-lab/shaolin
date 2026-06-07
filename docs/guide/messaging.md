# Messaging: integration-event ports

`shaolin-messaging` (v0.1.0) is the **transport-agnostic messaging layer**: a tiny set of
ports that domain logic and reactors depend on. Domain events are **never published
verbatim** — a `Reactor` maps each domain event to a curated `IntegrationEvent` envelope
(an anti-corruption boundary), which a `Publisher` sends out. In a monolith the
`InMemoryPublisher` is enough; flipping on a concrete broker adapter (e.g.
`Shaolin::RabbitMQ::Publisher` via bunny) is the **monolith → microservice switch** —
no domain or reactor code changes.

```ruby
require "shaolin/messaging"
```

Everything lives under `Shaolin::Messaging`. There are **no ENV vars** read by this gem
(broker config lives in the adapter gems).

---

## Surface at a glance

| Symbol | Kind | Purpose |
| --- | --- | --- |
| `Shaolin::Messaging` | module | Namespace + `topic_for` helper |
| `Shaolin::Messaging::IntegrationEvent` | class | Versioned wire envelope |
| `Shaolin::Messaging::Publisher` | module (mixin) | Outbound port — `#publish` |
| `Shaolin::Messaging::InMemoryPublisher` | class | In-process publisher; records `#published` |
| `Shaolin::Messaging::Reactor` | class | Base: domain event → curated integration event |
| `Shaolin::Messaging::VERSION` | constant | `"0.1.0"` |

---

## `IntegrationEvent`

The versioned envelope that crosses the wire.

```ruby
def initialize(event_type:, payload: {}, schema_version: 1, occurred_at: nil,
               correlation_id: nil, producer: nil)
```

| kwarg | default | notes |
| --- | --- | --- |
| `event_type:` | — (required) | Dotted name, e.g. `"users.user_registered"`. Doubles as the topic (see `topic_for`). |
| `payload:` | `{}` | The curated, consumer-facing data hash. |
| `schema_version:` | `1` | Bump when the payload shape changes; lets consumers branch. |
| `occurred_at:` | `nil` | Caller-supplied timestamp; **not** auto-populated. |
| `correlation_id:` | `nil` | Trace/correlation id; caller-supplied. |
| `producer:` | `nil` | Producing service/module name. Reactors inject this (see below). |

All six are exposed as `attr_reader` (`event_type`, `schema_version`, `occurred_at`,
`correlation_id`, `producer`, `payload`).

**Methods**

| method | signature | purpose |
| --- | --- | --- |
| `#to_h` | `to_h` | Symbol-keyed hash of all six fields (order: `event_type`, `schema_version`, `occurred_at`, `correlation_id`, `producer`, `payload`). |
| `#to_json` | `to_json(*)` | `JSON.generate(to_h)`. Accepts/ignores any args so it works with `JSON.generate`'s nested calls. |

```ruby
event = Shaolin::Messaging::IntegrationEvent.new(
  event_type: "users.user_registered",
  payload: { id: "u1", email: "a@b.com" },
  correlation_id: "c1",
  producer: "users"
)
event.schema_version          # => 1
event.to_h[:event_type]       # => "users.user_registered"
JSON.parse(event.to_json)["payload"]["id"]  # => "u1"
```

> **Gotchas.** `occurred_at` is `nil` unless you pass it — the gem does not stamp time.
> `require "json"` is done by the file itself, so `to_json` always works after
> `require "shaolin/messaging"`. There is no validation: any object is accepted for any
> field.

---

## `Publisher` (port)

The outbound port — a mixin defining the contract a broker adapter must satisfy.

```ruby
module Shaolin::Messaging::Publisher
  def publish(_integration_event)
    raise NotImplementedError, "#{self.class} must implement #publish"
  end
end
```

| method | signature | purpose |
| --- | --- | --- |
| `#publish` | `publish(integration_event)` | Send the envelope. Default raises `NotImplementedError`; concrete adapters override it. |

```ruby
class MyPublisher
  include Shaolin::Messaging::Publisher

  def publish(integration_event)
    # ...hand off to broker, return the event
    integration_event
  end
end
```

> **Gotcha.** Including the module without overriding `#publish` raises
> `NotImplementedError` ("`<ClassName> must implement #publish`") at call time, not load
> time.

---

## `InMemoryPublisher`

In-process publisher for monolith/dev/test: records everything it publishes.

```ruby
def initialize          # no args
attr_reader :published  # Array of IntegrationEvents, in publish order
def publish(integration_event)  # appends, returns the same event
```

| method | signature | purpose |
| --- | --- | --- |
| `#initialize` | `initialize` | Starts with empty `@published = []`. |
| `#published` | `published` | The array of events captured so far. |
| `#publish` | `publish(integration_event)` | Appends to `published`, returns the event. |

```ruby
publisher = Shaolin::Messaging::InMemoryPublisher.new
event = Shaolin::Messaging::IntegrationEvent.new(event_type: "x.y")
publisher.publish(event)
publisher.published   # => [#<IntegrationEvent event_type="x.y" ...>]
```

> **Gotcha.** It records but never forwards anywhere — assert on `#published` in specs.

---

## `Reactor`

Base class: subscribe to a domain event and publish a **curated** integration event.
Declare the mapping with the class macro `publishes`.

**Class methods**

| method | signature | purpose |
| --- | --- | --- |
| `.publishes` | `publishes(integration_type, &mapper)` | Declares the target `event_type` and a block that maps a domain event to a payload hash. Stores both at class level. |
| `.integration_type` | `integration_type` | `attr_reader` — the declared dotted type (or `nil`). |
| `.mapper` | `mapper` | `attr_reader` — the mapper proc (or `nil`). |

**Instance methods**

| method | signature | purpose |
| --- | --- | --- |
| `#initialize` | `initialize(publisher, producer: nil)` | `publisher` (positional, required) is any `Publisher`; `producer:` is stamped onto every emitted event. |
| `#call` | `call(domain_event)` | Builds and publishes the `IntegrationEvent`. Returns whatever `publisher#publish` returns. |

**Mapping rules (`#call`)**

- Payload = `self.class.mapper.call(domain_event)` if a `mapper` block was given,
  **else** falls back to `domain_event.data`.
- The emitted envelope is
  `IntegrationEvent.new(event_type: self.class.integration_type, payload: payload, producer: @producer)`
  — so `schema_version` is always `1` and `occurred_at`/`correlation_id` are `nil` here
  (this port doesn't set them).

```ruby
class UserReactor < Shaolin::Messaging::Reactor
  publishes "users.user_registered" do |event|
    { id: event.data[:id], email: event.data[:email] } # curated — internal fields dropped
  end
end

publisher = Shaolin::Messaging::InMemoryPublisher.new
domain_event = Struct.new(:data).new({ id: "u1", email: "a@b.com", secret: "hidden" })

UserReactor.new(publisher, producer: "users").call(domain_event)

published = publisher.published.first
published.event_type  # => "users.user_registered"
published.payload     # => { id: "u1", email: "a@b.com" }  (:secret never leaks)
published.producer    # => "users"
```

Without a block, the whole `domain_event.data` is forwarded:

```ruby
class PassthroughReactor < Shaolin::Messaging::Reactor
  publishes "audit.raw"   # no block
end
PassthroughReactor.new(publisher).call(domain_event)
publisher.published.last.payload  # => { id: "u1", email: "a@b.com", secret: "hidden" }
```

> **Gotchas.**
> - `publishes` and its `integration_type`/`mapper` are stored **per class** via `class << self`
>   `attr_reader`; subclasses that don't call `publishes` will see `nil` and emit an event
>   with `event_type: nil`.
> - The block receives the raw domain event; it must respond to whatever you call on it
>   (the no-block fallback requires `#data`).
> - `producer` defaults to `nil` — pass it at construction to identify the source service.

---

## `Messaging.topic_for`

Resolve the topic name an integration event publishes to.

```ruby
def self.topic_for(name_or_event)
  name_or_event.respond_to?(:event_type) ? name_or_event.event_type.to_s : name_or_event.to_s
end
```

| arg | behavior |
| --- | --- |
| an `IntegrationEvent` (anything responding to `event_type`) | returns `event_type.to_s` |
| a String/Symbol/other | returns `to_s` of it |

Because `event_type` already follows the dotted convention, it **doubles as the topic
name** — there is no separate topic registry.

```ruby
event = Shaolin::Messaging::IntegrationEvent.new(event_type: "billing.invoice_paid")
Shaolin::Messaging.topic_for(event)  # => "billing.invoice_paid"
Shaolin::Messaging.topic_for("a.b")  # => "a.b"
Shaolin::Messaging.topic_for(:"c.d") # => "c.d"
```

> **Gotcha.** Duck-typed on `respond_to?(:event_type)` — any object with that method is
> treated as an event, otherwise `to_s` is used.

---

## End-to-end

```ruby
require "shaolin/messaging"

class OrderShippedReactor < Shaolin::Messaging::Reactor
  publishes "orders.order_shipped" do |event|
    { order_id: event.data[:order_id], tracking: event.data[:tracking] }
  end
end

publisher = Shaolin::Messaging::InMemoryPublisher.new   # swap for a broker adapter in prod
reactor   = OrderShippedReactor.new(publisher, producer: "orders")

domain_event = Struct.new(:data).new({ order_id: "o7", tracking: "Z9", cost_cents: 500 })
reactor.call(domain_event)

ie = publisher.published.first
Shaolin::Messaging.topic_for(ie)  # => "orders.order_shipped"
ie.payload                        # => { order_id: "o7", tracking: "Z9" }  (cost_cents dropped)
```

Going to production: replace `InMemoryPublisher.new` with a concrete `Publisher`
(e.g. the RabbitMQ adapter). The reactor, envelope, and `topic_for` are unchanged.

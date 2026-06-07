# RabbitMQ adapter

`shaolin-rabbitmq` is the RabbitMQ transport for shaolin, built on **bunny** (`~> 2.22`,
pure Ruby — no system library, unlike Kafka's librdkafka). It is the wire transport for the
[`shaolin-messaging`](./messaging.md) ports:

- `Shaolin::RabbitMQ::Publisher` implements the `Shaolin::Messaging::Publisher` port: serializes a
  `Shaolin::Messaging::IntegrationEvent` to JSON and publishes it to a **topic exchange** with
  `routing_key = event_type`. It is a drop-in for `Shaolin::Messaging::InMemoryPublisher` — swapping
  transports is a one-line change.
- `Shaolin::RabbitMQ::Consumer` subscribes to a queue (bound to one or more routing keys) and yields each
  parsed envelope (a Hash with symbol keys). The app maps the envelope to a Command on the command bus —
  the same write path as HTTP.

```ruby
require "shaolin/rabbitmq"   # loads Publisher + Consumer (also pulls shaolin/messaging)
```

`Shaolin::RabbitMQ::VERSION` is the gem version string (`"0.1.0"`).

---

## Reliability model

Reactors publish **through the outbox**. A reactor's side effect is `publisher.publish(...)`, and
`shaolin worker` runs it from the transactional outbox — so delivery is **at-least-once** even across a
crash between the DB commit and the broker publish. Because delivery can be duplicated, **consumers must be
idempotent** (key on `event_id` / `correlation_id`).

Domain events are **never** published verbatim. A `Shaolin::Messaging::Reactor` maps a domain event to a
curated `IntegrationEvent`, so internal refactors don't break downstream consumers.

---

## `Shaolin::RabbitMQ::Publisher`

Publishes integration events to a durable topic exchange. `include`s `Shaolin::Messaging::Publisher`, so
`described_class.new(...).is_a?(Shaolin::Messaging::Publisher)` holds. Inject an `exchange` in tests;
otherwise it lazily opens a bunny connection on first publish.

| Method | Signature | Purpose |
|---|---|---|
| `.new` | `new(exchange: nil, url: ENV["RABBITMQ_URL"], exchange_name: "shaolin", breaker: nil)` | Build a publisher. |
| `#publish` | `publish(integration_event)` | JSON-encode and publish; returns the `integration_event` unchanged. |

**Constructor kwargs**

| Kwarg | Default | Purpose |
|---|---|---|
| `exchange:` | `nil` | Inject a pre-built bunny exchange (or a test double responding to `publish(payload, routing_key:)`). When `nil`, a bunny connection/channel/topic exchange is created lazily on first publish. |
| `url:` | `ENV["RABBITMQ_URL"]` | AMQP URL passed to `Bunny.new`. Only used when `exchange:` is `nil`. |
| `exchange_name:` | `"shaolin"` | Topic exchange name (declared `durable: true`). Must match the `Consumer`. |
| `breaker:` | `nil` | Optional `Shaolin::CircuitBreaker`. When present, every publish runs inside `breaker.call { ... }`, fast-failing during a broker brownout instead of piling up doomed connections (#25). |

`#publish` routes on `integration_event.event_type` and sends `integration_event.to_json`. The lazily
created exchange opens a `Bunny` session, starts it, and declares a `durable: true` topic exchange named
`exchange_name`.

```ruby
require "shaolin/rabbitmq"

# Lazy bunny connection (reads RABBITMQ_URL):
publisher = Shaolin::RabbitMQ::Publisher.new

event = Shaolin::Messaging::IntegrationEvent.new(
  event_type: "users.user_registered",
  payload: { id: "u1" }
)
publisher.publish(event)   # => the same event; sent to exchange "shaolin", routing_key "users.user_registered"
```

With a circuit breaker (production-grade outbound guard):

```ruby
breaker   = Shaolin::CircuitBreaker.new(threshold: 5, reset_timeout: 30)
publisher = Shaolin::RabbitMQ::Publisher.new(breaker: breaker)
publisher.publish(event)   # after `threshold` consecutive failures, raises Shaolin::CircuitBreaker::OpenError
```

In tests, inject any object responding to `publish(payload, routing_key:)`:

```ruby
exchange  = double = []  # stand-in; real test uses an object capturing [payload, routing_key]
publisher = Shaolin::RabbitMQ::Publisher.new(exchange: exchange)
```

> **Gotcha.** `breaker:` wraps the publish but does not swallow the error — the first failures still
> `raise` through; the breaker only short-circuits *subsequent* calls with `OpenError` once it has tripped.

---

## `Shaolin::RabbitMQ::Consumer`

Subscribes to a queue and yields each integration-event envelope (a Hash with **symbol keys**). Inject a
`queue` in tests; otherwise use `.connect` to build a bunny-backed queue bound to the exchange.

| Method | Signature | Purpose |
|---|---|---|
| `.connect` | `connect(queue:, routing_keys:, url: ENV["RABBITMQ_URL"], exchange_name: "shaolin")` | Open bunny, declare the topic exchange + durable queue, bind the routing keys, return a `Consumer`. |
| `.new` | `new(queue:)` | Wrap an existing bunny queue (or a test double responding to `subscribe(block:)`). |
| `#run` | `run { |envelope| ... }` | Subscribe with `block: true` (blocks the calling thread/process) and yield each parsed envelope. |
| `#parse` | `parse(body)` | `JSON.parse(body, symbolize_names: true)`. |

**`.connect` kwargs**

| Kwarg | Default | Purpose |
|---|---|---|
| `queue:` | — (required) | Queue **name** (declared `durable: true`). |
| `routing_keys:` | — (required) | Array of topic routing keys to `bind` the queue to (e.g. `["users.*", "billing.invoice_paid"]`). |
| `url:` | `ENV["RABBITMQ_URL"]` | AMQP URL passed to `Bunny.new`. |
| `exchange_name:` | `"shaolin"` | Topic exchange to bind to (declared `durable: true`). Must match the `Publisher`. |

`#run` calls `@queue.subscribe(block: true)` — it **blocks**, so run it in a dedicated worker process. Each
delivery is parsed (`symbolize_names: true`) and passed to the block.

```ruby
require "shaolin/rabbitmq"

consumer = Shaolin::RabbitMQ::Consumer.connect(
  queue: "billing-service",
  routing_keys: ["users.user_registered", "orders.*"]
)

consumer.run do |envelope|
  # envelope is the parsed IntegrationEvent hash with symbol keys:
  #   { event_type:, schema_version:, occurred_at:, correlation_id:, producer:, payload: }
  case envelope[:event_type]
  when "users.user_registered"
    command_bus.call(ProvisionAccount.new(id: envelope.dig(:payload, :id)))
  end
end
```

> **Gotchas.**
> - `#run` blocks forever; it is meant for a worker process, never an HTTP request fiber.
> - Both sides declare `durable: true` on the exchange/queue — names must agree across services.
> - The yielded envelope is a plain Hash, not an `IntegrationEvent` instance; consumers should treat
>   delivery as at-least-once and de-dupe on `correlation_id`.

---

## The envelope: `Shaolin::Messaging::IntegrationEvent`

The versioned envelope that crosses the wire (defined in `shaolin-messaging`). The `Publisher` serializes
it; the `Consumer` reconstructs the same shape as a symbol-keyed Hash.

`new(event_type:, payload: {}, schema_version: 1, occurred_at: nil, correlation_id: nil, producer: nil)`

| Field | Default | Notes |
|---|---|---|
| `event_type:` | — (required) | Becomes the routing key. Convention: `"<module>.<event>"` (e.g. `"users.user_registered"`). |
| `payload:` | `{}` | Curated, public-contract data (not the raw domain event). |
| `schema_version:` | `1` | Envelope version for consumer compatibility. |
| `occurred_at:` | `nil` | Producer-set timestamp. |
| `correlation_id:` | `nil` | De-dup / tracing key — use it on the consumer side. |
| `producer:` | `nil` | Producing service identifier. |

`#to_h` returns all six fields; `#to_json` is `JSON.generate(to_h)` — exactly what `Publisher#publish` sends.

---

## Wiring through a reactor (the normal producer path)

A `Shaolin::Messaging::Reactor` declares `publishes "<type>" do |event| {...} end` and, when invoked by the
worker from the outbox, maps a domain event to an `IntegrationEvent` and calls `publisher.publish(...)`.

```ruby
class UserReactor < Shaolin::Messaging::Reactor
  publishes "users.user_registered" do |event|
    { id: event.data[:id], email: event.data[:email] }
  end
end

# In production, the publisher is the RabbitMQ adapter; in tests, InMemoryPublisher.
UserReactor.new(Shaolin::RabbitMQ::Publisher.new).call(domain_event)
```

---

## Live-broker note

The gem is **unit-tested against a mock channel — no broker is needed for the test suite**. For a real
cross-service demo, start a broker and point `RABBITMQ_URL` at it:

```bash
docker run -d -p 5672:5672 rabbitmq:3      # or: apt install rabbitmq-server
export RABBITMQ_URL=amqp://guest:guest@localhost:5672
```

- **Service A:** command → event → outbox → `shaolin worker` → `Publisher#publish`.
- **Service B:** `Consumer#run` → map envelope → command on its own bus.

---

## Environment variables

| Var | Used by | Default | Purpose |
|---|---|---|---|
| `RABBITMQ_URL` | `Publisher#initialize`, `Consumer.connect` | — (`nil`) | AMQP connection URL passed to `Bunny.new`. Only consulted when no `exchange:`/`queue:` is injected. |

---

## Testing

Both classes accept an injected collaborator so tests need no broker:

```ruby
# Publisher: inject an object responding to publish(payload, routing_key:)
exchange = Class.new do
  attr_reader :published
  def initialize = (@published = [])
  def publish(payload, routing_key:) = (@published << [payload, routing_key])
end.new
Shaolin::RabbitMQ::Publisher.new(exchange: exchange).publish(event)

# Consumer: inject an object responding to subscribe(block:)
queue = Class.new do
  def initialize(body) = (@body = body)
  def subscribe(block:) = yield(nil, nil, @body)
end.new(JSON.generate(event_type: "billing.invoice_paid", payload: { id: "i1" }))
Shaolin::RabbitMQ::Consumer.new(queue: queue).run { |env| handle(env) }
```

Prefer `Shaolin::Messaging::InMemoryPublisher` for monolith/dev/test where you only need to assert what was
published.

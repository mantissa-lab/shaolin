# shaolin-rabbitmq

RabbitMQ transport for [shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-jobs-microservices-design.md),
via **bunny** (pure Ruby — no system library, unlike Kafka's librdkafka).

- `Shaolin::RabbitMQ::Publisher` implements the `Shaolin::Messaging::Publisher` port: publishes an
  `IntegrationEvent` envelope (JSON) to a topic exchange with `routing_key = event_type`. Drop-in
  for the in-memory publisher — swapping transports is one line.
- `Shaolin::RabbitMQ::Consumer` subscribes to a queue (bound to routing keys) and yields each parsed
  envelope; the app maps it to a Command on the command bus (same write path as HTTP).

## Reliability

Reactors publish **through the outbox**: a reactor's side effect is `publisher.publish(...)`, and the
`shaolin worker` runs it from the transactional outbox — so delivery is at-least-once even across a
crash between the DB commit and the broker publish. Consumers should be idempotent (key on
`event_id`/`correlation_id`).

## Live two-service demo

Unit-tested with a mock channel (no broker needed). For a real cross-service demo start a broker:

```bash
docker run -d -p 5672:5672 rabbitmq:3      # or: apt install rabbitmq-server
export RABBITMQ_URL=amqp://guest:guest@localhost:5672
```

Service A: command → event → outbox → `shaolin worker` → `Publisher#publish`.
Service B: `Consumer#run` → map envelope → command on its own bus.

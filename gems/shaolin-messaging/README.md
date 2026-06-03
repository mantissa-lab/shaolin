# shaolin-messaging

Transport-agnostic messaging **ports** for [shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-messaging-kafka-design.md).
Domain logic and reactors depend only on these ports; a concrete broker adapter binds them. In a
monolith the in-process publisher is enough — flipping on a broker adapter is the
monolith → microservice switch.

## Pieces

- `Shaolin::Messaging::IntegrationEvent` — the versioned envelope that crosses the wire
  (`event_type`, `schema_version`, `occurred_at`, `correlation_id`, `producer`, `payload`).
  Domain events are never published verbatim; reactors map them to curated integration events
  (anti-corruption boundary).
- `Shaolin::Messaging::Publisher` — the outbound port (`#publish(integration_event)`).
- `Shaolin::Messaging::InMemoryPublisher` — in-process default (records `#published`); used in
  monolith/dev/test.
- `Shaolin::Messaging::Reactor` — base that maps a domain event to an integration event:

  ```ruby
  class UserReactor < Shaolin::Messaging::Reactor
    publishes "users.user_registered" do |event|
      { id: event.data[:id], email: event.data[:email] } # curated payload
    end
  end
  UserReactor.new(publisher).call(domain_event)
  ```
- `Shaolin::Messaging.topic_for(event)` — the topic name (the dotted `event_type`).

## Kafka adapter — deferred

`shaolin-kafka` (Karafka + WaterDrop over `karafka-rdkafka`) is **not built yet** because this
environment lacks **librdkafka** (`apt install librdkafka-dev` is required to build the native
extension). The ports here are the stable contract; the Kafka adapter is a later drop-in: a
`WaterDropPublisher` implementing `Publisher`, and Karafka consumers mapping inbound messages to
commands. No domain or reactor code changes when it lands.

See the [design spec](../../docs/superpowers/specs/2026-06-03-shaolin-messaging-kafka-design.md).

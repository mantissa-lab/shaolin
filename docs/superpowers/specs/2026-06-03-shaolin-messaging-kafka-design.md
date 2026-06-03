# shaolin-messaging + shaolin-kafka — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** [shaolin-core](2026-06-03-shaolin-core-design.md), [shaolin-cqrs](2026-06-03-shaolin-cqrs-design.md), [shaolin-dto](2026-06-03-shaolin-dto-design.md)
**Sub-project:** 6 of 10 (messaging transport — the monolith→microservice switch)

This sub-project is **two gems**: `shaolin-messaging` (transport-agnostic ports) and
`shaolin-kafka` (the Kafka implementation). The split is what makes "flick a switch to go
microservice" real: domain logic and reactors depend only on the ports; adding `shaolin-kafka`
binds those ports to Kafka.

## 1. Purpose

- **shaolin-messaging:** define the *ports* — an outbound **Publisher** (emit integration events)
  and an inbound **MessageConsumer** (carry external messages → commands) — plus the integration-
  event envelope, the reactor contract (domain event → integration event), and topic naming. No
  broker specifics.
- **shaolin-kafka:** implement those ports on **Karafka** (consumers) + **WaterDrop** (producer)
  over `karafka-rdkafka`.

In **monolith mode** (no shaolin-kafka), domain events are handled in-process by shaolin-cqrs
subscribers; nothing crosses a broker. Adding **shaolin-kafka** turns selected reactors into Kafka
publishers and activates inbound consumers — the same code, a different wiring.

## 2. Foundation (verified 2026-06-03)

- **Karafka 2.5.x** consumer: `class C < Karafka::BaseConsumer; def consume; messages.each { |m| m.payload }; end; end`.
  Centralized routing: `App.routes.draw { topic(:orders) { consumer OrdersConsumer } }` (consumer
  *class*, not instance). Multi-threaded; runs as its own long-lived process.
- **WaterDrop ≥ 2.8.14** producer: `WaterDrop::Producer.new { |c| c.kafka = { 'bootstrap.servers': … } }`;
  `produce_sync(topic:, payload:, key:, headers:)` → delivery report; `produce_async`;
  `enable.idempotence` for exactly-once-ish semantics; tombstones for compacted topics.
- **karafka-rdkafka ≥ 0.24** (librdkafka FFI) underneath.

> Karafka runs its own thread pool in a separate process — orthogonal to Falcon's request fibers.
> Exact Karafka 2.5 standalone routing/boot API confirmed at planning.

## 3. Integration-event envelope (shaolin-messaging)

A stable, versioned envelope decouples internal domain events from what crosses the wire:

```
{
  "event_id":      "<uuid>",
  "event_type":    "users.user_registered",
  "schema_version": 1,
  "occurred_at":   "<iso8601>",
  "correlation_id":"<uuid>",        # propagated from the originating command/request
  "producer":      "<service-name>",
  "payload":       { ... }          # explicit, curated fields — NOT the raw domain event
}
```

- Kafka **headers** carry `event_type`, `schema_version`, `correlation_id` for cheap routing/filtering;
  the body is the JSON envelope.
- **Domain events are never published verbatim.** A reactor maps a domain event to a curated
  integration event, so internal refactors don't break consumers (anti-corruption boundary).

## 4. Reactor contract (domain → integration)

- A **reactor** subscribes (via shaolin-cqrs's event bus) to selected domain events and calls the
  **Publisher** port with an integration event. Reactors live in a module's `reactors/` folder and
  declare their mappings; the manifest's `events_published` lists the integration events a module
  emits (contract surface for agents).
- The Publisher port: `publisher.publish(integration_event)` — synchronous by default (delivery
  confirmed), async opt-in for high throughput.

## 5. Inbound: messages → commands

- A module's `consumers/` define inbound subscriptions. shaolin-kafka maps each to a Karafka
  consumer + route. On each message the flow is:
  `message → parse envelope → validate with the module's DTO → build Command → command_bus.(cmd)`.
- This is **the same write path as HTTP** — the command bus doesn't know the command arrived via
  Kafka. Guarantees and validation are identical across transports.
- **Idempotency:** inbound handlers key on `event_id`/`correlation_id` so redelivery is safe
  (matches the event-store's optimistic concurrency on the write side).

## 6. Topic naming & convention

- Convention: `<service>.<aggregate>.<event>` (e.g. `billing.invoice.paid`), centralized in
  `Shaolin::Messaging.topic_for(integration_event)` — never hand-built.
- A module subscribes to other services' topics by declaring them in its manifest
  (`imports events: ["billing.invoice_paid"]`), which shaolin-kafka turns into Karafka routes.

## 7. Process & deploy shape

- **Producer** (WaterDrop) is in-process and usable from any app (incl. the Cloud Run HTTP app) to
  publish integration events.
- **Consumers** (Karafka) are **long-running** → deployed as a separate **GKE Deployment**
  (always-on worker), per the production-runtime spec. `shaolin-cli` provides a `shaolin karafka
  server` entrypoint for that image.
- Graceful shutdown: producer flush + Karafka shutdown wired into the kernel lifecycle.

## 8. Kernel integration (providers)

```ruby
# shaolin-kafka
Shaolin.register_provider(:kafka_producer) do
  start { # build WaterDrop producer (idempotence on); register "messaging.publisher" }
  stop  { # flush + close producer }
end

Shaolin.register_provider(:kafka_consumers) do   # only in worker process
  start { # build Karafka routes from each module's consumers + manifest event imports }
  stop  { # shutdown Karafka }
end
```

shaolin-messaging registers the **port interfaces** and a **null/in-process publisher** default
(used in monolith mode and tests); shaolin-kafka swaps in the real publisher.

## 9. Public API

- shaolin-messaging: `Shaolin::Messaging::Publisher` (port), `IntegrationEvent` (envelope value
  object), `Shaolin::Messaging.topic_for(...)`, `Shaolin::Messaging::Reactor` base.
- Container keys: `messaging.publisher` (in-process default or Kafka), consumer routing built by
  the kafka_consumers provider.
- shaolin-kafka: `Shaolin::Kafka::Consumer` base (wraps `Karafka::BaseConsumer`), producer config.

## 10. Error handling

- **Producer delivery failure:** idempotent producer with bounded retries; on persistent failure,
  `Failure` surfaced to the reactor (logged, optionally to an outbox for retry — outbox is a later
  cycle, noted not silently dropped).
- **Consumer processing error:** Karafka retry policy → **DLQ** topic after N attempts; poison
  messages isolated, not blocking the partition.
- **Schema mismatch** (unknown `schema_version`) → routed to DLQ with a clear reason.

## 11. Testing strategy

- `waterdrop` test/buffered producer to assert published envelopes without a live broker.
- `karafka-testing` to drive consumers with synthetic messages; assert the resulting command was
  dispatched.
- Contract test: a domain event → reactor → exact integration envelope (schema-locked).
- RSpec; TDD.

## 12. To verify during planning

- Karafka 2.5 standalone (non-Rails) routing/boot API and the consumer worker entrypoint.
- WaterDrop idempotence + delivery-report handling and graceful flush semantics.
- karafka-rdkafka / librdkafka availability and build on the target container base image.
- Ruby 4.0 compatibility of the Karafka stack.
- Outbox pattern need for guaranteed publish (defer to a later cycle; confirm cycle-1 uses
  synchronous publish-after-commit and document the at-least-once caveat).

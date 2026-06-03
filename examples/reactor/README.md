# examples/reactor — async reactors over the transactional outbox

A minimal shaolin app showing the async side of the framework: a `signups` module
with a `SignupCompleted` event and a `NotifyReactor` that publishes an integration
event for other services.

## What it proves

```
event_store.publish(SignupCompleted)
        │  (same DB transaction)
        ▼
  shaolin_jobs outbox row  ──►  shaolin worker  ──►  NotifyReactor#call
                                                          │
                                                          ▼
                                       messaging.publisher.publish(IntegrationEvent)
```

The outbox row is written **atomically with the event**, so the side effect can never
be lost. The reactor runs later in `shaolin worker` (here: one `run_once`), and delivery
is at-least-once — reactors must be idempotent.

## Run it

```bash
createdb -h /tmp -p 5433 -U postgres shaolin_reactor_example   # one time
ruby examples/reactor/verify.rb
```

`DB_NAME`/`DB_HOST`/`DB_PORT`/`DB_USER` override the connection (defaults: a local
Postgres on `/tmp:5433`).

## Going cross-service

Swap the in-memory publisher in `config/boot.rb` for `Shaolin::RabbitMQ::Publisher`
(same `Shaolin::Messaging::Publisher` port) and run `shaolin worker`; a second service
consumes with `Shaolin::RabbitMQ::Consumer`. Nothing in the reactor changes.

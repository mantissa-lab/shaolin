# shaolin 🥋

A standalone, modular **CQRS / Event-Sourcing** backend framework for Ruby. Not Rails — but
Rails-ecosystem gems (ActiveRecord first) work out of the box. Every entity is a self-contained
folder you can hand to its own agent. Built to be **LLM-operable** end to end.

> Status: working. 7 gems, 73 tests green, a demo app proven on PostgreSQL + Falcon.

## Why

- **Modules are folders.** Each entity lives in `app/modules/<name>/` with an explicit public
  contract (`module.rb` manifest + `CONTRACT.md`). Isolation is enforced by the kernel.
- **CQRS + Event Sourcing at the core.** Commands mutate event-sourced aggregates; events are the
  source of truth (Postgres event store); projections build read models you query.
- **Transport-agnostic.** A controller (HTTP) and a Kafka consumer are thin adapters over the same
  command/query buses. Run a modular monolith, or flick on messaging for microservices.
- **Production by default.** Falcon (async) or Puma; `shaolin new` generates a Dockerfile and a
  Cloud Run / Knative manifest.
- **LLM-friendly by construction.** Deterministic conventions, generators, explicit `require`s, a
  generated `AGENTS.md`, and machine-readable contracts.

## Quickstart

```bash
shaolin new shop && cd shop
shaolin g module orders          # full CQRS/ES module, boots immediately
shaolin server                   # Falcon on http://localhost:8080

curl -X POST localhost:8080/orders -H 'content-type: application/json' -d '{"name":"Widget"}'
# 201 Created, Location: /orders/<uuid>
curl localhost:8080/orders/<uuid>
# {"id":"<uuid>","name":"Widget"}
```

## The flow

```
HTTP request
  → DTO validation (dry-validation)
  → Command (typed value object)
  → command bus → CommandHandler
  → Aggregate (event-sourced) emits a domain Event
  → Event store (ActiveRecord + ruby_event_store, Postgres)
  → Projection updates a read model (ActiveRecord)
GET → query the read model → JSON
```

Write and read are fully separated (CQRS); state is rebuilt by replaying events (ES).

## Gems

| Gem | Responsibility |
|---|---|
| `shaolin-core` | kernel: module registry, DI (dry-system), boot lifecycle, isolation |
| `shaolin-cqrs` | command/query buses, aggregates, projections, event store wiring |
| `shaolin-activerecord` | event-store backend + read models + migrations |
| `shaolin-dto` | boundary validation + typed value objects |
| `shaolin-http` | controllers → commands/queries; Rack app (hanami-router) |
| `shaolin-server` | Falcon/Puma adapters + graceful shutdown |
| `shaolin-cli` | `shaolin new` / `g module` generators + runners |

## Develop the framework

```bash
bundle install
cd gems/shaolin-core && bundle exec rspec   # per-gem suites
bundle exec ruby examples/demo/verify.rb    # the demo, end-to-end
```

See [`llms.txt`](llms.txt) and [`AGENTS.md`](AGENTS.md) to drive shaolin as an agent, and
`docs/superpowers/specs/` for the design specs.

## License

MIT.

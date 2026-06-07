# shaolin 🥋

A standalone, modular **CQRS / Event-Sourcing** backend framework for Ruby. Not Rails — but
Rails-ecosystem gems (ActiveRecord first) work out of the box. Every entity is a self-contained
folder you can hand to its own agent. Built to be **LLM-operable** end to end.

> Status: working. 14 gems (one umbrella `shaolin` + 13 components), 226 tests green, a demo app
> proven on PostgreSQL + Falcon.

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

## Install

shaolin is distributed via (private) **git**, not RubyGems. One line in an app's `Gemfile` pulls the
whole framework — Bundler's `glob:` exposes every gemspec in the repo so the umbrella resolves all
sub-gems (you need read access to the repo):

```ruby
gem "shaolin", git: "git@github.com:mantissa-lab/shaolin.git", glob: "gems/*/*.gemspec"
```

```ruby
# config/boot.rb
require "shaolin"
```

`shaolin new` scaffolds this for you. Pin a `tag:`/`branch:` for reproducible builds.

## Quickstart

```bash
shaolin new shop && cd shop
shaolin g module orders          # plain CRUD module, boots immediately (add --es for CQRS/ES)
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

One umbrella gem pulls the whole stack — an app's `Gemfile` is just `gem "shaolin"` and boot is a single
`require "shaolin"`:

| Gem | Responsibility |
|---|---|
| **`shaolin`** | **umbrella — depends on + `require`s everything below; ships the `shaolin` CLI** |
| `shaolin-core` | kernel: module registry, DI (dry-system), boot lifecycle, isolation |
| `shaolin-cqrs` | command/query buses, aggregates, projections, event store wiring |
| `shaolin-activerecord` | event-store backend + read models + migrations (with drift detection) |
| `shaolin-dto` | boundary validation + typed value objects |
| `shaolin-http` | controllers → commands/queries; Rack app (hanami-router) + OpenAPI/Swagger |
| `shaolin-server` | Falcon/Puma adapters + graceful shutdown |
| `shaolin-cli` | `shaolin new` / `g module` generators + runners + `lint`/`graph`/`describe` |
| `shaolin-messaging` | transport-agnostic integration-event ports (Kafka adapter deferred) |
| `shaolin-jobs` | transactional outbox, worker, scheduler, cross-module reactors |
| `shaolin-redis` | Redis cache, KV store, and Streams/Pub-Sub broker |
| `shaolin-rabbitmq` | RabbitMQ integration-event broker |
| `shaolin-llm` | provider-agnostic LLM chat + realtime/audio substrate (OpenAI adapter) |
| `shaolin-harness` | event-sourced LLM harness: gate state machine + durable/sync runners |

## Develop the framework

```bash
bundle install
cd gems/shaolin-core && bundle exec rspec   # per-gem suites
bundle exec ruby examples/demo/verify.rb    # the demo, end-to-end
```

**Full reference:** [`docs/GUIDE.md`](docs/GUIDE.md) — the complete, current guide (every layer + best
practices), and [`llms.txt`](llms.txt) for the condensed agent map. Also [`AGENTS.md`](AGENTS.md),
[`CHANGELOG.md`](CHANGELOG.md), and [`docs/EVENTS.md`](docs/EVENTS.md) (event evolution + operating the
store at scale). The pre-build design docs under `docs/superpowers/specs/` are **historical** — GUIDE.md
and llms.txt are the source of truth.

## License

MIT.

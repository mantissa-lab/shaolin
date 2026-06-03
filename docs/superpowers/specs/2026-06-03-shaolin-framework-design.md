# shaolin — Design Spec

**Date:** 2026-06-03
**Status:** Approved (brainstorming) — pending written-spec review
**Author:** andres.fonollosa@umbrella-trade.com (with Claude)

## 1. Vision

**shaolin** is a standalone, modular Ruby backend framework built around **CQRS and Event
Sourcing**. It is *not* Rails, but Rails-ecosystem gems (ActiveRecord first and foremost) work
out of the box because shaolin loads them as ordinary libraries. Its purpose is to produce
**fully independent, modular, event-sourced backends** where every entity lives in a
self-contained folder — NestJS-style — so isolated that any single module can be handed to its
own maintenance agent without it needing to understand the rest of the system.

The same codebase runs as a **modular monolith** (in-process command/event buses, HTTP) or, by
flicking on a messaging transport (Kafka), as **event-driven microservices** — the NestJS
monolith-vs-microservice duality, expressed through events.

## 2. Goals

- Self-contained module folders with an explicit public contract (commands handled, events
  published, queries served).
- **Event Sourcing + CQRS at the core**: state is derived by replaying events; write and read
  models are separate.
- Dependency injection and module autoloading as the substrate, transport-agnostic.
- ActiveRecord in two roles: **event-store backend** and **read-model / projection store**.
- Rails-ecosystem gems usable without friction.
- Production-ready HTTP server out of the box (Falcon, async-first).
- Container-native: every generated app ships a production Dockerfile and is deployable
  GCP-first (Cloud Run / GKE) or to its open-source equivalent (Knative on k8s). No bespoke
  Rails-Kamal-style deploy.
- Pluggable messaging transport (Kafka first): domain events bridged to integration events.
- The framework *itself* is clean and modular — small single-responsibility components, no
  monster files. It dogfoods the philosophy it imposes.

## 3. Non-Goals (for now)

- A custom ORM or query builder (ActiveRecord).
- A custom DI container from scratch (dry-system).
- A custom event store / replay / snapshotting engine (ruby_event_store).
- RabbitMQ adapter in cycle 1 (messaging abstraction is generic; Kafka is first).
- GraphQL, WebSockets, admin UI, auth framework — later cycles.

## 4. Guiding Principles

1. **Commands & events are the core; transports are adapters.** Aggregates and handlers know
   nothing about HTTP or Kafka. A controller and a Kafka consumer are thin adapters that
   *produce commands* or *carry events*. This makes monolith ↔ microservice a switch.
2. **Module isolation = agent-ownership boundary.** A module sees only what it `imports`; only
   its `exports` (and published events) are visible to others. An agent owning `users/` can
   refactor internals freely without breaking neighbors.
3. **Write/read separation.** The write side is event-sourced aggregates + an append-only event
   store. The read side is projections into ActiveRecord read models, queried independently.
4. **The framework is modular too.** The kernel is split into focused gems, each independently
   testable. No file grows into a 10k-line monolith.
5. **Verify, never invent.** Ruby and gem versions/APIs are confirmed via context7/web research
   before being committed to design, plan, or code.
6. **LLM-friendly by construction.** The framework is designed to be operated by AI agents, not
   just humans. Ruthlessly predictable conventions (deterministic layout; naming derives keys,
   stream names, table names); machine-readable contracts (`module.rb` manifest + `CONTRACT.md` +
   `shaolin describe --json` emitting the whole app map); structured introspection and an MCP
   server exposing describe/lint/test/graph as tools; actionable errors that state the fix; small
   single-responsibility files that fit a context window; correct-by-construction generators;
   explicit schemas for every command/event; and a generated `AGENTS.md`/`CLAUDE.md` so an agent
   dropped into a repo is oriented instantly. This is not a feature — it is a cross-cutting
   constraint on every sub-project.

## 5. Tech Stack (verified 2026-06-03)

| Concern | Choice | Notes |
|---|---|---|
| Language | Ruby **4.0.5** | Latest stable (4.0 line shipped 2025-12-25). Verify all gem compat with Ruby 4.0 during planning. |
| DI / loader | **dry-system 1.x** + **dry-auto_inject 1.x** | Ruby ≥ 3.0 ✓. |
| Event sourcing | **ruby_event_store** + **aggregate_root** (RES, Arkency, 2.7.x) | Framework-agnostic toolkit; AR-backed event store; pub/sub; snapshots. |
| Event store backend | **ActiveRecord** (rails_event_store_active_record) | Postgres. |
| Validation | **dry-validation / dry-schema** (DTO + command contracts) | Consistent with dry-rb. |
| Result/errors | **dry-monads** (`Success`/`Failure`) | Transport-independent domain errors. |
| Read models / ORM | **ActiveRecord** (primary) | Projection tables; fiber-safe pool (Rails ≥ 7.1) for async. |
| HTTP router | **hanami-router** (Rack 3 compatible) | Thin shaolin convention layer. Pin exact version in planning. |
| Web server | **Falcon 0.36.x** (default, async-first) | Puma available as opt-in adapter; kernel is server-agnostic. |
| Async model | **Ruby Fiber Scheduler** (3.0+) via `async` | Transparent (no `async/await` keywords); fiber-per-request. |
| Messaging | **Karafka 2.5.x** + **WaterDrop ≥ 2.8.14** + **karafka-rdkafka ≥ 0.24** | Domain → integration events to Kafka; inbound messages → commands. |
| Tests | **RSpec** (+ ruby_event_store-rspec matchers) | Per-module isolation; TDD during implementation. |

> Exact patch versions are pinned at `Gemfile.lock` time during planning, confirmed via
> context7/web — not asserted here.

## 6. Distribution: framework as a monorepo of gems

One repository, several independent gems, so the framework stays modular and testable in parts:

- `shaolin-core` — kernel: boot, module registry, manifest DSL, DI wiring over dry-system.
- `shaolin-cqrs` — CQRS/ES building blocks: command bus, event store wiring (ruby_event_store),
  event bus / pub-sub, query bus, aggregate base, projection runner.
- `shaolin-http` — Rack/hanami-router adapter; controllers map requests to commands/queries.
- `shaolin-activerecord` — AR integration: event-store backend config, read-model tables,
  per-module migrations, fiber-safe pool.
- `shaolin-messaging` — transport abstraction (producer/consumer ports); domain↔integration
  event bridging contract.
- `shaolin-kafka` — messaging impl via Karafka + WaterDrop.
- `shaolin-server` — server adapters (Falcon default, Puma opt-in), lifecycle, graceful shutdown.
- `shaolin-cli` — generators and runners (`new`, `g module`, `g aggregate/command/event/...`,
  `server`, `console`, projection rebuild).
- `shaolin` — meta-gem wiring sensible defaults together.

## 7. Module anatomy (NestJS-style, CQRS/ES)

```
app/modules/users/
  module.rb                  # manifest: imports[...], exports[...], commands_handled, events_published
  commands/
    register_user.rb         # command value object (dry-struct/contract)
  events/
    user_registered.rb       # domain event (RubyEventStore::Event)
  user_aggregate.rb          # AggregateRoot: apply_user_registered, invariants
  command_handlers/
    register_user_handler.rb # load aggregate (replay) -> call -> append events
  projections/
    users_projection.rb      # subscribes to events -> updates read model
  read_models/
    user_record.rb           # ActiveRecord read-model (projection table)
  queries/
    find_user.rb             # query handler reading read models
  controllers/
    users_controller.rb      # HTTP adapter -> command bus / query bus
  consumers/
    users_consumer.rb        # Kafka adapter (optional): message -> command, or publish events
  dto/
    register_user_dto.rb     # input validation at the boundary
  README.md / CONTRACT.md    # public interface, for the owning agent
```

`module.rb` declares `imports` (keys/events from other modules), `exports` (public components),
`commands_handled`, and `events_published`. This manifest *is* the isolation contract.

## 8. Kernel & CQRS/ES wiring

- **DI (dry-system):** each module is a sub-container auto-registering its components; the
  manifest's imports/exports map onto dry-system container import/export.
- **Command bus:** routes a command to its single handler (resolved from the module container).
- **Event store (ruby_event_store, AR-backed):** append-only; aggregates are rebuilt by
  replaying their stream; snapshots on a configurable interval.
- **Event bus / pub-sub:** subscribers (projections, reactors) react to published events.
- **Query bus:** routes queries to query handlers that read AR read models.
- **Projection runner:** builds/rebuilds read models from the event stream (CLI-invocable).
- Domain errors flow as `dry-monads` `Success`/`Failure`, never as transport status codes.

## 9. Data flows

**Write (command):**
`HTTP controller -> DTO validate -> dispatch Command on command bus -> command handler loads
Aggregate from event store (replay) -> aggregate enforces invariants and applies domain
event(s) -> handler appends events to the store -> event bus publishes -> projections update AR
read models (+ optional reactor publishes integration event to Kafka via WaterDrop).`

**Read (query):**
`HTTP controller -> dispatch Query on query bus -> query handler reads AR read model -> serialize
to JSON.`

**Kafka inbound:**
`Karafka consumer -> map message to a Command -> command bus` (same path as HTTP write).

**Domain vs integration events:** internal domain events live in the event store; a reactor
subscribes and publishes selected **integration events** to Kafka topics for other services.
Controller, consumer, and reactor are all thin adapters over the same command/event core.

## 10. Persistence (ActiveRecord, dual role)

- **Event store backend:** rails_event_store_active_record tables (Postgres).
- **Read models:** per-module projection tables; migrations namespaced per module.
- Connection via ENV (12-factor).
- **Async mode:** under Falcon, AR uses its fiber-safe connection pool (keyed by `Fiber.current`,
  Rails ≥ 7.1), fiber-per-request, with a `pg` build supporting concurrent queries. Pool sizing
  documented and configurable. No code coloring — handlers look synchronous, cooperate via the
  scheduler.

## 11. Error handling

Handlers return `Success`/`Failure` (dry-monads). Adapters translate at the edge:
`Failure(:validation)` -> HTTP 422 / Kafka DLQ; `Failure(:not_found)` -> 404; aggregate
invariant violation -> 409/422; unexpected -> 500 / Karafka retry policy. The domain never
references transport codes.

## 12. CLI & generators

`shaolin new myapp` · `shaolin g module users` ·
`shaolin g aggregate|command|event|projection|read_model|query|controller|consumer` ·
`shaolin server` · `shaolin console` · `shaolin projections rebuild [name]`.

Generators produce the section-7 layout including `module.rb` and `CONTRACT.md`, and (for
`shaolin new`) the production runtime artifacts in section 13.

## 13. Production runtime & deploy (GCP-first, container-native)

`shaolin new` generates:

- **Dockerfile** — multi-stage (build → slim runtime), non-root user, exec-form `ENTRYPOINT`
  (app as PID 1 to receive SIGTERM), binds to `$PORT` (default 8080), healthcheck.
- **.dockerignore** and an **entrypoint** that runs AR migrations (event store + read models)
  then starts the server.
- **Deploy manifest by app type:** HTTP app → `service.yaml` for **Cloud Run / Knative**;
  Kafka-consumer / projection-worker app (long-running) → **GKE Deployment** manifest
  (always-on). Optional `cloudbuild.yaml`.
- **12-factor config:** all configuration via ENV; secrets via Secret Manager/env.
- **Graceful shutdown:** SIGTERM handler with the Cloud Run ~10s grace window, built into the
  server adapter and kernel lifecycle (drains in-flight, closes AR pool, flushes producers).

Open-source path without vendor lock-in: the same containers run on **Knative/k8s**.

## 14. Testing strategy

- Each module testable in isolation: boot only that module's container, stub imports; assert on
  emitted events (ruby_event_store-rspec matchers) and on projected read models.
- Each framework gem has its own suite.
- RSpec; implementation proceeds by TDD.

## 15. Decomposition into sub-projects

Each gets its own spec → plan → implementation cycle, in **dependency order** (kernel first, as
everything imports it):

1. **shaolin-core** — boot, module registry, manifest DSL, DI over dry-system.
2. **shaolin-cqrs** — command bus, event store (ruby_event_store), event bus, query bus,
   aggregate base, projection runner.
3. **shaolin-activerecord** — event-store backend + read models + per-module migrations +
   fiber-safe pool.
4. **shaolin-http** — router conventions, base controller, command/query dispatch.
5. **DTO / validation** — boundary + command contracts (may fold into shaolin-cqrs).
6. **shaolin-messaging + shaolin-kafka** — domain↔integration events, inbound message→command.
7. **shaolin-server** — Falcon/Puma adapters, lifecycle, graceful shutdown.
8. **shaolin-cli** — generators and runners.
9. **Production runtime & deploy** — Docker + Cloud Run/Knative/GKE artifacts.
10. **Agent-ownership tooling** — per-module CONTRACT, isolation guarantees, lint.
11. **LLM / agent interface** — `shaolin describe --json` (full app map), MCP server exposing
    describe/lint/test/graph/routes as tools, `AGENTS.md`/`CLAUDE.md` generation, machine-readable
    schemas. Cross-cuts every gem; this sub-project delivers the dedicated surfaces.

## 16. Cycle 1 scope — thin vertical slice through every layer

Prove the whole CQRS/ES concept end to end, each layer minimal but complete:

`shaolin new app` → `shaolin g module users` → a `User` **aggregate** with a `RegisterUser`
command and a `UserRegistered` event, a command handler, a projection into an AR read model, a
query, HTTP endpoints (POST command + GET query) on Falcon, **plus** one Kafka consumer
(message → command) and one reactor publishing an integration event via WaterDrop, **plus** a
generated production Dockerfile + Cloud Run manifest.

Touches: kernel + CQRS/ES + event store (AR) + read models + HTTP (Falcon) + DTO + CLI/generator
+ Kafka + Docker/deploy — shallow depth, full width. Later cycles deepen each layer.

## 17. To verify during planning

- Ruby 4.0 compatibility of: ActiveRecord, dry-system/dry-auto_inject, ruby_event_store/
  aggregate_root/rails_event_store_active_record, hanami-router, Falcon, Karafka stack. Pin
  exact versions.
- ruby_event_store dispatcher behavior under the fiber scheduler (sync vs async subscribers).
- hanami-router exact version and Rack 3 behavior under Falcon.
- AR fiber-safe pool config under Falcon (pool size formula, `pg` concurrent queries).
- Cloud Run / Knative manifest schema for a Ruby/Falcon container.

## 18. Risks

- **CQRS/ES complexity:** event sourcing is a steep model; even cycle 1's "users" is now an
  aggregate with commands/events/projections. Mitigation: lean on ruby_event_store conventions;
  generators scaffold the full slice so the model is learnable by example.
- **Async-first (Falcon) + AR + RES dispatcher:** needs careful pool/fiber config and a clear
  decision on sync vs async event dispatch. Mitigation: sane defaults + docs; Puma adapter as
  the safe fallback; default to synchronous in-process dispatch, async opt-in.
- **Ruby 4.0 gem maturity:** some gems may lag a brand-new major. Mitigation: verify each at
  planning; ready to target 3.4.9 if a critical gem is incompatible.
- **Cycle-1 breadth:** widest possible first cycle risks spreading thin. Mitigation: keep each
  layer to the minimum that proves the vertical slice; resist deepening any layer in cycle 1.

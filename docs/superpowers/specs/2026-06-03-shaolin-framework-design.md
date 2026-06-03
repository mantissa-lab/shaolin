# shaolin — Design Spec

**Date:** 2026-06-03
**Status:** Approved (brainstorming) — pending written-spec review
**Author:** andres.fonollosa@umbrella-trade.com (with Claude)

## 1. Vision

**shaolin** is a standalone, modular Ruby backend framework. It is *not* Rails, but
Rails-ecosystem gems (ActiveRecord first and foremost) work out of the box because shaolin
loads them as ordinary libraries. Its purpose is to produce **fully independent, modular
backends** where every entity lives in a self-contained folder — NestJS-style — so isolated
that any single module can be handed to its own maintenance agent without it needing to
understand the rest of the system.

The same codebase can run as a **modular monolith** (HTTP) or, by flicking on a messaging
transport (Kafka/RabbitMQ), as a **microservice** — exactly the NestJS monolith-vs-microservice
duality.

## 2. Goals

- Self-contained module folders with an explicit public contract (NestJS-style: controller /
  service / module-manifest / dto).
- Dependency injection and module autoloading as the core, transport-agnostic.
- ActiveRecord as the primary ORM; Rails-ecosystem gems usable without friction.
- Production-ready HTTP server out of the box.
- Container-native: every generated app ships a production Dockerfile and is deployable to
  GCP-first infra (Cloud Run / GKE) or its open-source equivalent (Knative on k8s). No
  bespoke Rails-Kamal-style deploy.
- Pluggable messaging transport (Kafka first) for microservice mode.
- The framework *itself* is clean and modular — small single-responsibility components, no
  monster files. It dogfoods the philosophy it imposes.

## 3. Non-Goals (for now)

- A custom ORM or query builder (we use ActiveRecord).
- A custom DI container from scratch (we stand on dry-system).
- RabbitMQ adapter in cycle 1 (messaging abstraction is generic; Kafka is the first impl).
- GraphQL, WebSockets, admin UI, auth framework — later cycles.

## 4. Guiding Principles

1. **Transport-agnostic core.** Business logic (service / use-case) knows nothing about HTTP
   or Kafka. A controller and a Kafka consumer are two thin adapters over the *same* service.
   This is what makes "monolith ↔ microservice with a switch" real.
2. **Module isolation = agent-ownership boundary.** A module sees only what it `imports`; only
   its `exports` are visible to others. An agent owning `users/` can refactor internals freely
   without breaking neighbors.
3. **The framework is modular too.** The kernel is split into focused gems, each independently
   testable. No file is allowed to grow into a 10k-line monolith.
4. **Verify, never invent.** Ruby and gem versions/APIs are confirmed via context7/web research
   before being committed to design, plan, or code.

## 5. Tech Stack (verified 2026-06-03)

| Concern | Choice | Notes |
|---|---|---|
| Language | Ruby **4.0.5** | Latest stable (4.0 line shipped 2025-12-25). Verify all gem compat with Ruby 4.0 during planning. |
| DI / loader | **dry-system 1.x** + **dry-auto_inject 1.x** | Ruby ≥ 3.0 ✓. Deps: dry-configurable/dry-core/dry-inflector 1.x. |
| Validation | **dry-validation / dry-schema** (DTO contracts) | Consistent with dry-rb foundation. |
| Result/errors | **dry-monads** (`Success`/`Failure`) | Transport-independent domain errors. |
| ORM | **ActiveRecord** (primary) | Fiber-safe connection pool (Rails ≥ 7.1) for async mode. |
| HTTP router | **hanami-router** (Rack 3 compatible) | Thin shaolin convention layer on top. Pin exact version in planning. |
| Web server | **Falcon 0.36.x** (default, async-first) | Puma available as opt-in adapter. Kernel is server-agnostic. |
| Async model | **Ruby Fiber Scheduler** (3.0+) via `async` | Transparent (no `async/await` keywords); fiber-per-request. |
| Messaging | **Karafka 2.5.x** + **WaterDrop ≥ 2.8.14** + **karafka-rdkafka ≥ 0.24** | Kafka consumer framework + producer, on librdkafka. |
| Tests | **RSpec** | Per-module isolation; TDD during implementation. |

> Exact patch versions are pinned at `Gemfile.lock` time during planning, confirmed via
> context7/web — not asserted here.

## 6. Distribution: framework as a monorepo of gems

One repository, several independent gems, so the framework stays modular and testable in parts:

- `shaolin-core` — kernel: boot, module registry, manifest DSL, DI wiring over dry-system.
- `shaolin-http` — Rack/hanami-router adapter, router conventions, base controller.
- `shaolin-activerecord` — ActiveRecord integration: connection, per-module models & migrations,
  fiber-safe pool config.
- `shaolin-messaging` — transport abstraction (producer/consumer ports).
- `shaolin-kafka` — messaging impl via Karafka + WaterDrop.
- `shaolin-server` — server adapters (Falcon default, Puma opt-in), lifecycle & graceful shutdown.
- `shaolin-cli` — generators and runners (`new`, `g module`, `server`, `console`).
- `shaolin` — meta-gem wiring sensible defaults together.

## 7. Module anatomy (NestJS-style)

```
app/modules/users/
  module.rb              # manifest: name, imports[...], exports[...]
  users_controller.rb    # HTTP adapter: routes -> service calls
  users_consumer.rb      # Kafka adapter (optional): topic -> same service
  user_service.rb        # business logic; dependencies via DI
  user.rb                # ActiveRecord model
  dto/
    create_user_dto.rb   # dry-validation contract at the boundary
  README.md / CONTRACT.md  # public interface, for the owning agent
```

`module.rb` declares `imports` (keys exported by other modules) and `exports` (its own public
components). This manifest *is* the isolation contract.

## 8. Kernel & DI (dry-system mapping)

- Each module is a dry-system sub-container that auto-registers components from its own folder.
- The manifest's `imports`/`exports` map onto dry-system's container import/export mechanism: a
  module can only resolve keys it explicitly imported; only exported keys are exposed outward.
- Services and controllers receive dependencies through `dry-auto_inject`.
- Domain errors flow as `dry-monads` `Success`/`Failure`, never as transport status codes.

## 9. Transport adapters

**HTTP flow:**
`Rack request -> shaolin router resolves controller from the module container -> action
validates input via DTO contract -> calls service (deps injected) -> service works through
ActiveRecord -> Result -> controller serializes to JSON.`

**Kafka flow:**
`Karafka consumer (generated per module subscription) -> maps message into a DTO -> calls the
SAME service method -> optionally produces via WaterDrop.`

Controller and consumer are twin thin adapters over one use-case — the core never changes when
you add or remove a transport.

## 10. Persistence (ActiveRecord)

- Models live inside their module folder; migrations are namespaced per module.
- Connection configured via ENV (12-factor).
- **Async mode:** under Falcon, AR uses its fiber-safe connection pool (keyed by `Fiber.current`,
  Rails ≥ 7.1) with fiber-per-request isolation and a `pg` build supporting concurrent queries.
  Pool sizing is documented and configurable. No code coloring — services look synchronous and
  cooperate via the scheduler.

## 11. Error handling

Services return `Success`/`Failure` (dry-monads). Adapters translate at the edge:
`Failure(:validation)` -> HTTP 422 / Kafka DLQ; `Failure(:not_found)` -> 404; unexpected ->
500 / Karafka retry policy. The domain layer never references transport codes.

## 12. CLI & generators

`shaolin new myapp` · `shaolin g module users` · `shaolin g controller|service|dto` ·
`shaolin server` · `shaolin console`.

Generators produce the section-7 folder layout including `module.rb` and `CONTRACT.md`, and (for
`shaolin new`) the production runtime artifacts in section 13.

## 13. Production runtime & deploy (GCP-first, container-native)

`shaolin new` generates:

- **Dockerfile** — multi-stage (build → slim runtime), non-root user, exec-form `ENTRYPOINT`
  (app as PID 1 so it receives SIGTERM), binds to `$PORT` (default 8080), healthcheck.
- **.dockerignore** and an **entrypoint** that runs AR migrations then starts the server.
- **Deploy manifest by app type:** HTTP app → `service.yaml` for **Cloud Run / Knative**;
  Kafka-consumer app (long-running) → **GKE Deployment** manifest (always-on). Optional
  `cloudbuild.yaml`.
- **12-factor config:** all configuration via ENV; secrets via Secret Manager/env.
- **Graceful shutdown:** SIGTERM handler with the Cloud Run ~10s grace window, built into the
  server adapter and kernel lifecycle (drains, closes AR pool).

Open-source path without vendor lock-in: the same containers run on **Knative/k8s** with no
proprietary GCP dependency.

## 14. Testing strategy

- Each module is testable in isolation: boot only that module's container, stub its imports.
- Each framework gem has its own suite.
- RSpec; implementation proceeds by TDD.

## 15. Decomposition into sub-projects

Each gets its own spec → plan → implementation cycle:

1. Kernel (boot, module registry, manifest DSL, DI over dry-system).
2. HTTP transport (router conventions, base controller).
3. Persistence / ActiveRecord (per-module models & migrations, fiber-safe pool).
4. DTO / validation (boundary contracts).
5. CLI / generators.
6. Messaging transport (Kafka via Karafka/WaterDrop).
7. Production runtime & deploy artifacts.
8. Agent-ownership tooling (per-module CONTRACT, isolation guarantees).

## 16. Cycle 1 scope — thin vertical slice through every layer

Prove the whole concept end to end, each layer minimal but complete:

`shaolin new app` → `shaolin g module users` → a self-contained `users/` folder with
controller/service/module/dto and an AR model, wired through DI, serving an HTTP CRUD endpoint
on Falcon, **plus** one Kafka consumer and one producer bound to the same service — and a
generated production Dockerfile + Cloud Run manifest.

This touches: kernel + HTTP (Falcon) + ActiveRecord + DTO + CLI/generator + Kafka + Docker/deploy
artifacts — shallow depth, full width. Later cycles deepen each layer.

## 17. To verify during planning

- Ruby 4.0 compatibility of: ActiveRecord, dry-system/dry-auto_inject, hanami-router, Falcon,
  Karafka/WaterDrop/karafka-rdkafka. Pin exact versions.
- hanami-router exact version and Rack 3 behavior under Falcon.
- AR fiber-safe pool config specifics under Falcon (pool size formula, `pg` concurrent queries).
- Cloud Run / Knative manifest schema specifics for a Ruby/Falcon container.

## 18. Risks

- **Async-first default (Falcon) + AR** needs careful pool/fiber configuration; misconfiguration
  causes connection leaks. Mitigation: ship sane defaults + docs; Puma adapter as the safe fallback.
- **Ruby 4.0 gem maturity:** some gems may lag on a brand-new major. Mitigation: verify each at
  planning; be ready to target 3.4.9 if a critical gem is incompatible.
- **Cycle-1 breadth:** widest possible first cycle risks spreading thin. Mitigation: keep each
  layer to the minimum that proves the vertical slice; resist deepening any layer in cycle 1.

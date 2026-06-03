# shaolin-cli — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** all runtime gems (orchestrates them); generators encode the conventions of
[shaolin-core](2026-06-03-shaolin-core-design.md) / [shaolin-cqrs](2026-06-03-shaolin-cqrs-design.md)
**Sub-project:** 8 of 10 (developer tooling — the framework's front door)

## 1. Purpose

`shaolin-cli` is the `shaolin` executable: it **scaffolds projects**, **generates modules and
their CQRS/ES artifacts** in the canonical folder layout, and provides **runners** (server, Kafka
worker, console) and **db tasks**. It is how a developer (or an agent) creates a self-contained,
agent-ownable module without hand-wiring anything.

## 2. Foundation (verified 2026-06-03)

- **Thor** — the Ruby CLI/generator standard (used by bundler, rails). Commands are public
  methods; `Thor::Group` builds multi-step generators; `Thor::Actions` provides
  `add_file`/`copy_file`/`template`/`directory`/`inject_into_file`; templates are ERB.

> Thor version pinned at planning; confirm Ruby 4.0 compat.

## 3. Command surface

```
shaolin new <app>                      # scaffold a new project (see §4)
shaolin g module <name>                # scaffold a full CQRS/ES module (see §5)
shaolin g aggregate|command|event|projection|read_model|query|controller|consumer|reactor|dto <name>
shaolin server                         # boot app + serve HTTP (shaolin-server)
shaolin karafka server                 # boot app + run Kafka consumers (worker process)
shaolin console                        # IRB/Pry with the app booted (containers resolvable)
shaolin db:create_event_store          # install RES event-store schema
shaolin db:migrate | db:rollback       # run/rollback per-module read-model migrations
shaolin projections rebuild [name]     # replay events to rebuild read model(s)
shaolin routes                         # print mounted HTTP routes + Kafka subscriptions
```

Runners and db tasks are **thin delegations** to the runtime gems (server lifecycle,
activerecord migrator, cqrs projection runner) — the CLI adds no logic of its own there.

## 4. `shaolin new` — project skeleton

Generates a runnable, production-ready skeleton:

- `Gemfile` (shaolin meta-gem + chosen extras), `.ruby-version` = **4.0.5**.
- `config/` — app boot, ENV-driven config, server adapter (Falcon default).
- `app/modules/` (empty, ready for `g module`).
- **Production artifacts** (from the production-runtime spec): multi-stage `Dockerfile`,
  `.dockerignore`, container entrypoint (migrate → serve), `deploy/service.yaml` (Cloud Run/Knative)
  and `deploy/worker.yaml` (GKE) templates, `.env.example`.
- `spec/` with RSpec + the shaolin test helpers.
- `README` documenting the module workflow.

## 5. `shaolin g module <name>` — the keystone generator

Scaffolds the full canonical module (parent spec §7) so the CQRS/ES model is learnable by example:

```
app/modules/<name>/
  module.rb              # manifest (imports/exports/commands_handled/events_published) — pre-filled
  commands/<verb>_<name>.rb
  events/<name>_<pasttense>.rb
  <name>_aggregate.rb    # include AggregateRoot, apply + on handler
  command_handlers/<verb>_<name>_handler.rb   # with_aggregate + dry-monads
  projections/<name>s_projection.rb
  read_models/<name>_record.rb               # Shaolin::AR::ReadModel
  queries/find_<name>.rb
  controllers/<name>s_controller.rb          # routes DSL, validate→dispatch→render
  consumers/<name>s_consumer.rb              # optional (flag --kafka)
  reactors/<name>_reactor.rb                 # optional (flag --kafka)
  dto/<verb>_<name>_dto.rb
  db/migrate/<ts>_create_<name>s_read.rb     # read-model migration
  CONTRACT.md            # generated public-interface doc for the owning agent
  spec/...               # generated specs for aggregate/handler/projection/controller
```

Flags: `--kafka` (include consumer + reactor), `--no-http`, `--aggregate-only`. The generated
module **boots and passes its generated specs immediately** — the scaffold is correct by
construction, not a stub.

## 6. Modular generator design (dogfooding)

- **One generator class per artifact** (`AggregateGenerator`, `CommandGenerator`, …), each a small
  `Thor::Group`; `ModuleGenerator` composes them. No monolithic generator file — the CLI obeys the
  same small-single-responsibility rule the framework preaches.
- Naming/inflection (file → container key, stream names, table names) is delegated to a shared
  `Shaolin::CLI::Naming` helper so conventions live in exactly one place and match shaolin-core's
  resolver.
- Templates are ERB under `templates/`, one per artifact, kept minimal and convention-pure.

## 7. CONTRACT.md generation

For every module, the generator emits a `CONTRACT.md` summarizing: commands handled, events
published/subscribed, exports, and HTTP routes — derived from the manifest. This is the artifact an
**owning agent reads first** to understand the module's boundary without opening internals. (Agent-
ownership tooling, sub-project 10, keeps it in sync.)

## 8. Public API

- `bin/shaolin` → `Shaolin::CLI::Main` (Thor).
- `Shaolin::CLI::Generators::*` (one per artifact) + `ModuleGenerator`.
- `Shaolin::CLI::Naming` — shared inflection/convention helper.

## 9. Error handling

- **Outside a project** (`g`, `server`, `db:*` with no `config/`): clear error telling the user to
  run inside a shaolin app or use `shaolin new`.
- **Name collision / existing file:** never silently overwrite — prompt (`Thor` conflict handling)
  or refuse with `--force` required.
- **Invalid name** (not a valid Ruby/module identifier): reject with guidance.

## 10. Testing strategy

- Generator specs: run each generator into a tmp dir; assert exact files produced and that an
  app with the generated module **boots** and its generated specs pass (correct-by-construction).
- CLI command specs: `routes`, `db:*`, runners delegate correctly (with runtime gems stubbed).
- RSpec; TDD.

## 11. To verify during planning

- Thor version + Ruby 4.0 compat; `Thor::Actions` template/conflict APIs.
- Whether `console` uses IRB (Ruby 4.0 default) or Pry; how to boot the app for resolution.
- Read-model migration timestamp/versioning scheme (coordinate with shaolin-activerecord).
- Exact generated-spec content so "boots and passes" holds across all artifact combinations.

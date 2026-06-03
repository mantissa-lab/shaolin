# shaolin-core — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Sub-project:** 1 of 10 (foundation — every other gem imports it)

## 1. Purpose

`shaolin-core` is the kernel. It boots an application, discovers and registers **modules**
(self-contained folders), wires **dependency injection** over dry-system, and enforces the
**module isolation contract** (a module sees only what it `imports`; only its `exports` are
visible outward). It is the substrate on which `shaolin-cqrs`, `shaolin-http`,
`shaolin-activerecord`, etc. are built.

It defines the **public contracts** that all other sub-projects depend on: the module manifest
DSL, the container/registry API, the boot lifecycle, and the injection mixin.

## 2. Responsibilities

- Discover modules under a configured root (e.g. `app/modules/*`).
- Build one **dry-system sub-container per module** with auto-registration of that module's
  components from its folder.
- Provide the **manifest DSL** (`Shaolin::Module`) for declaring `imports` and `exports`.
- Wire imports/exports between module containers using dry-system's import mechanism.
- Provide the **injection mixin** (`Deps[...]`) backed by dry-auto_inject.
- Manage the **boot lifecycle** (discover → configure → register → wire → finalize) with a
  provider/lifecycle hook system for sub-projects to plug into (e.g. CQRS buses, AR connection).
- Expose an **application object** (`Shaolin::App`) as the composition root.

## 3. Non-Responsibilities (owned elsewhere)

- Commands/events/aggregates/projections → `shaolin-cqrs`.
- HTTP routing/controllers → `shaolin-http`.
- ActiveRecord/event-store/read-models → `shaolin-activerecord`.
- Server lifecycle (Falcon/Puma) → `shaolin-server`.
- Generators → `shaolin-cli`.

`shaolin-core` knows nothing about HTTP, AR, Kafka, or CQRS. Those plug in via the
provider/lifecycle hooks (section 7).

## 4. Foundation: dry-system / dry-auto_inject (verified 2026-06-03)

- dry-rb has rebranded to **Hanakai**; docs at hanakai.org (gems still `dry-*`). dry-system 1.x.
- A container is a `Dry::System::Container` subclass; `config.component_dirs` drives
  auto-registration from folders.
- Cross-container sharing uses dry-system **imports** (a container imports selected keys from
  another, under a namespace).
- Reusable lifecycle components are **providers** (start/stop hooks).
- `finalize!` boots the container; `container["key"]` resolves a component.
- Injection: `Dry::AutoInject(container)` → `include Import["key"]` (keyword-arg injection).

> Exact dry-system v1.2 method signatures (import options, provider DSL, component_dir options)
> are confirmed against hanakai.org `/learn/dry/dry-system/v1.2/` during planning, not invented here.

## 5. Module manifest DSL

Each module folder has a `module.rb`:

```ruby
Shaolin.module "users" do
  # what this module needs from others (resolved from their exports)
  imports "notifications.mailer"
  imports events: ["billing.invoice_paid"]   # event subscriptions (consumed by shaolin-cqrs)

  # what this module exposes to others (default: nothing is public)
  exports "user_service", "queries.find_user"

  # declared for tooling / contracts (validated, surfaced in CONTRACT.md)
  commands_handled "register_user"
  events_published "user_registered"
end
```

Semantics:
- **`imports`** — keys this module may resolve from other modules' exports. Resolving a
  non-imported key raises at boot. `events:` declares cross-module event subscriptions
  (wired by shaolin-cqrs against the manifest).
- **`exports`** — the only keys other modules can import. Everything else is module-private.
- **`commands_handled` / `events_published`** — declarative metadata: validated against what
  actually exists, surfaced into `CONTRACT.md`, and consumed by agent-ownership tooling. They
  do not themselves wire behavior (shaolin-cqrs does), but they make the contract explicit.

The manifest is the **single source of truth for a module's public boundary** — the artifact an
owning agent reads to understand the module without opening its internals.

## 6. Module → container mapping

- Each module = a dry-system sub-container (a "slice"), auto-registering components from its
  folder by naming convention (`user_service.rb` → `"user_service"`, `queries/find_user.rb`
  → `"queries.find_user"`).
- The root `Shaolin::App` container holds the modules and brokers imports/exports: at wire time,
  for each module's declared `imports`, core configures a dry-system import of exactly those
  keys from the owning module, refusing anything not in that module's `exports`.
- Injection inside a module uses a module-scoped `Deps` mixin: `include Deps["user_repository"]`
  resolves first from the module's own container, then from its imports — never from arbitrary
  global keys.

## 7. Boot lifecycle & provider hooks

Ordered phases, each extensible by other gems via registered hooks:

1. **discover** — find `app/modules/*/module.rb`, load manifests into the **module registry**.
2. **configure** — load app config from ENV (12-factor); validate manifests (exports exist,
   no import cycles, declared commands/events resolve).
3. **register** — build each module's container; auto-register components.
4. **providers** — run provider start hooks (CQRS buses, AR connection, etc. register here).
5. **wire** — apply imports/exports between containers.
6. **finalize** — `finalize!` all containers; the app is ready.
7. **shutdown** — reverse provider stop hooks (used by graceful shutdown in shaolin-server).

Other gems integrate **only** through `Shaolin.register_provider(name) { start { } stop { } }`
and lifecycle callbacks — they never reach into core internals. This keeps core
CQRS/HTTP/AR-agnostic.

## 8. Public API (the contract other gems depend on)

- `Shaolin.module(name, &block)` — declare a module manifest.
- `Shaolin::App` — application/composition root; `App[key]`, `App.modules`, `App.boot!`,
  `App.shutdown!`.
- `Shaolin::Module` — manifest object: `#name`, `#imports`, `#exports`, `#commands_handled`,
  `#events_published`, `#container`.
- `Shaolin::Registry` — module registry: lookup, iteration, contract introspection.
- `Shaolin.register_provider(name, &block)` — lifecycle provider registration.
- `Deps[...]` (per-module injector) — dependency injection mixin.
- `Shaolin.config` — typed configuration (dry-configurable) sourced from ENV.

## 9. Error handling

- **Manifest errors** (export referenced that doesn't exist, import cycle, duplicate module)
  raise `Shaolin::ManifestError` at the configure phase with the offending module named.
- **Boundary violation** (resolving a non-imported/non-exported key) raises
  `Shaolin::IsolationError` naming the consumer, the key, and the owning module.
- **Boot failures** surface the failing provider/phase. Errors fail fast at boot, never silently.

## 10. Configuration

- All config via ENV (12-factor), typed through dry-configurable.
- Core config: `modules_path` (default `app/modules`), `env` (development/test/production),
  logging. Sub-projects add their own config namespaces via providers.

## 11. Testing strategy

- Boot a minimal app with synthetic modules in a tmp dir; assert registry contents, import/export
  wiring, and isolation enforcement (resolving a private key raises).
- Per-module isolation test helper: boot a single module with its imports stubbed.
- RSpec; TDD.

## 12. To verify during planning

- dry-system v1.2 exact API for: `component_dirs` options, cross-container `import`
  signature/namespace behavior, provider DSL, `finalize!` semantics, test-mode stubbing.
- Whether one container-per-module (many slices) or a single container with namespaces performs
  better for dozens of modules; benchmark at planning.
- dry-configurable 1.x API for ENV-sourced typed config.
- Ruby 4.0 compatibility of dry-system/dry-auto_inject/dry-configurable.

## 13. Open questions (resolve with downstream specs)

- Exact key-naming convention for nested folders (`queries/find_user.rb` → `queries.find_user`)
  — confirm against dry-system's default inflection and lock it as a shaolin convention.
- How event subscriptions declared in the manifest (`imports events: [...]`) hand off to
  shaolin-cqrs — define the precise provider contract in the shaolin-cqrs spec.

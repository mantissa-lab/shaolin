# Agent-ownership tooling — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** [shaolin-core](2026-06-03-shaolin-core-design.md) (manifest = the boundary),
[shaolin-cqrs](2026-06-03-shaolin-cqrs-design.md), [shaolin-cli](2026-06-03-shaolin-cli-design.md)
**Sub-project:** 10 of 10 (what makes "hand a folder to its own agent" real)

## 1. Purpose

This sub-project turns module isolation from a *convention* into an *enforced, verifiable
property*, so a single module folder can be handed to its own maintenance agent. The agent must be
able to **understand, change, test, and ship one module without reading or touching the rest of the
system** — and the framework must *prove* the module stayed inside its boundary.

Three pillars: a **contract artifact** (what the module promises), **isolation enforcement** (it
can't secretly depend on internals), and a **single-module work harness** (build/test it alone).

## 2. The boundary is the manifest

`module.rb` (`imports` / `exports` / `commands_handled` / `events_published`) is the single source
of truth. Everything here derives from it: the contract doc is generated from it, the linter checks
code against it, the test harness stubs everything outside it.

## 3. CONTRACT.md — the artifact an agent reads first

Generated from the manifest + code introspection, kept in sync (drift fails lint):

```
# users — module contract
Owner: <team-or-agent>
Commands handled:   RegisterUser, ...
Events published:   users.user_registered (v1)
Events subscribed:  billing.invoice_paid (v1)
Exports:            user_service, queries.find_user
Imports:            notifications.mailer
HTTP routes:        POST /users, GET /users/:id
```

This is the *whole* interface. An agent owning `users/` reads this, not the internals of other
modules — and other agents read *this* instead of `users/`'s internals.

## 4. Isolation enforcement (`shaolin lint:isolation`)

Static analysis using Ruby's in-core **Prism** parser (shipped with Ruby 3.4+/4.0) over each
module's AST:

- Flags any reference to **another module's internal constant** (anything not in that module's
  `exports`).
- Flags `require`/`require_relative` crossing module folders.
- Flags resolving a container key the module didn't `import`.
- Flags publishing/subscribing events not declared in the manifest.

Violations are reported as `module:file:line` with the rule and the fix (add an export/import, or
go through the public interface). Non-zero exit — wired into CI and pre-merge.

This is what makes the boundary **real**: an agent physically cannot reach into a neighbor without
the linter catching it.

## 5. Single-module work harness (`shaolin module <name> test|console|run`)

- Boots **only** the target module's container, with every import replaced by a **contract
  double** generated from the imported module's exports/events — so the agent needs none of the
  other modules running.
- Event subscriptions are driven by synthetic events matching the **published schema** of upstream
  modules (consumer-driven), so an agent can develop against `billing.invoice_paid` v1 without
  billing present.
- `shaolin module users test` runs just that module's specs in isolation; `console`/`run` boot it
  alone. This is the agent's sandbox.

## 6. Contract tests at boundaries (change safety)

- **Published-event contract tests:** each `events_published` has a locked schema; changing it
  without a version bump fails the contract test. Protects every downstream consumer (and Kafka
  integration events) from silent breakage.
- **Export contract tests:** an export's public signature is pinned; breaking it fails before merge.
- These are the safety net that lets an agent refactor internals freely (green internals + green
  contract = safe to ship) while guaranteeing it didn't break the promise others rely on.

## 7. Dependency & blast-radius view (`shaolin graph`)

Renders the module graph from manifests (imports + event pub/sub) as text/DOT: who depends on a
module, what a change to it can affect. An agent (or a human) sees the blast radius of a module
before touching it.

## 8. Ownership metadata

- Optional `owner:` in `module.rb` (team or agent id). `shaolin owners` emits a CODEOWNERS-style
  map (`app/modules/users/ → @users-agent`) for routing changes/reviews.
- Purely advisory; isolation enforcement does not depend on it.

## 9. Public surface (CLI)

- `shaolin lint:isolation` — boundary enforcement (Prism AST).
- `shaolin contract:check` — CONTRACT.md sync + event/export contract tests.
- `shaolin module <name> test|console|run` — single-module harness with contract doubles.
- `shaolin graph` — module dependency / blast-radius graph.
- `shaolin owners` — ownership map.
- `Shaolin::Contract` — contract-double + schema-lock helpers.

## 10. Error handling

- Lint/contract violations → non-zero, precise `module:file:line` + remediation.
- CONTRACT.md drift → fail with a diff and the regenerate command.
- Harness used outside a module / on a non-existent module → clear error.

## 11. Testing strategy

- Fixture modules with deliberate violations (cross-module constant, undeclared event) → assert the
  linter catches each.
- A module developed entirely against contract doubles boots and its specs pass with no sibling
  modules loaded (proves real isolation).
- Schema-lock tests: changing a published event without a version bump fails.
- RSpec; TDD.

## 12. To verify during planning

- Prism AST API on Ruby 4.0 for the isolation rules (constant resolution across files/modules).
- Contract-double generation from a module's exports/event schemas (reuse dry-struct/dry-schema).
- Consumer-driven contract format for events (align with the integration-event envelope schema in
  shaolin-messaging).
- Whether `graph` output should also emit an HTML/SVG view (defer unless needed).

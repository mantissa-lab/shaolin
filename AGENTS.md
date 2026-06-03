# AGENTS.md — working on the shaolin framework

This repo is the **shaolin framework** itself (a monorepo of gems), not an app built with it.
For driving shaolin *as a user/app author*, read [`llms.txt`](llms.txt).

## Layout

- `gems/shaolin-<name>/` — one gem per concern, each with its own `spec/` (RSpec).
  Dependency order: `core → cqrs → activerecord → http → dto → server → cli`.
- `examples/demo/` — a working `users` app; the reference the `g module` generator mirrors.
- `docs/superpowers/specs/` — design spec per sub-project.
- Root `Gemfile` wires all gems as path gems sharing one bundle.

## Conventions (non-negotiable)

- **TDD.** Write a failing spec, make it pass, commit. No file should grow past ~150 lines.
- **Verify, never invent.** Confirm gem versions/APIs against the installed gem (probe in a
  scratch script) before coding — this is how every gem here was built.
- **Each gem stays focused.** Cross-gem coupling goes through the kernel (`Shaolin::Kernel`,
  providers) and documented keys (`cqrs.*`, `http.app`, `kernel.containers`), never internals.
- **Small commits**, conventional prefixes (`feat(core):`, `feat(cqrs):`, ...).

## Run things

```bash
bundle install
cd gems/shaolin-<name> && bundle exec rspec     # a gem's suite (cd in first — cwd matters)
bundle exec ruby examples/demo/verify.rb        # demo end-to-end (needs Postgres)
RBENV_VERSION=4.0.5 bundle exec ruby gems/shaolin-cli/exe/shaolin g module foo   # the CLI
```

## Test database

Specs in `shaolin-activerecord` and `shaolin-cli` need PostgreSQL on port 5433 (socket `/tmp`,
dbs `shaolin_test` + `shaolin_demo`). Start a local cluster:

```bash
pg_ctl -D /tmp/shaolin-pg -o "-p 5433 -k /tmp" -l /tmp/shaolin-pg.log start
```

## Architecture in one breath

Kernel boots modules (one dry-system container each) and runs providers in order. The `:cqrs`
provider builds the buses + event store and auto-wires each module's command handlers and
projections. The `:http` provider assembles one Rack app from all controllers. `shaolin-server`
serves it. ActiveRecord backs both the event store and the read models. See
`docs/superpowers/specs/2026-06-03-shaolin-framework-design.md`.

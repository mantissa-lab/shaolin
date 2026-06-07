# CLI reference

The `shaolin` executable (gem `shaolin-cli`, `VERSION = "0.1.0"`) is the dev/ops
front door to a shaolin app. It is a [Thor](https://github.com/rails/thor)
command suite: `Shaolin::CLI::Main < Thor`. The binary (`exe/shaolin`) is just:

```ruby
require "shaolin/cli"
require "shaolin/cli/main"
Shaolin::CLI::Main.start(ARGV)
```

`Main.exit_on_failure? => true` — any `Thor::Error` (and the `SystemExit` it
raises) becomes a non-zero exit, so the commands are CI-safe.

> The CLI is a **dev/binary tool** and is **not** loaded by `require "shaolin"`.
> Most commands first call the private `boot_app!`, which requires
> `./config/boot.rb` relative to the **current working directory** — run them
> from the app root, or they raise `not a shaolin app (no config/boot.rb in …)`.

## Command index

| Command | Boots app? | Purpose |
|---|---|---|
| `new APP` | no | Scaffold a new application |
| `generate` / `g` `module NAME` | no | Scaffold a module (CRUD default; `--es`, `--reactor`) |
| `generate` / `g` `field MODULE name:type` | no | Add a column migration + an edit checklist |
| `server` | yes | Boot and serve HTTP (Falcon by default) |
| `console` | yes | Boot and open an IRB console |
| `migrate` | yes | Apply event-store + jobs schema, run read-model migrations |
| `db reset` | yes | Drop + create + migrate (DEV ONLY) |
| `rollback [STEPS]` | yes | Roll back the last N read-model migrations |
| `worker` | yes | Run the jobs worker (drains the outbox) |
| `scheduler` | yes | Run the periodic-task scheduler |
| `jobs [ACTION] [ID]` | yes | Inspect the outbox (`stats`/`dead`/`retry`) |
| `projections rebuild [NAME]` | yes | Replay events into read models |
| `describe` | no | Machine-readable app map (manifest-level) |
| `schemas` | no | Each module's command/event surface (JSON) |
| `openapi` | yes | Generate an OpenAPI 3.1 document |
| `lint` | no | Static module-isolation check (Prism) |
| `graph` | no¹ | Module dependency graph from manifests |
| `routes` | yes | Modules + their commands/events |

¹ `graph` does not call `boot_app!`; it `require`s each `module.rb` directly.

---

## new

```
shaolin new APP [--path PATH]
```

Scaffolds a runnable app (`Generators::NewAppGenerator`). Creates a directory
named after the underscored app name with: `Gemfile`, `config/boot.rb`,
`bin/server` (chmod `0755`), `Dockerfile`, `AGENTS.md`, `README.md`,
`deploy/service.yaml`, `.env.example`, `.dockerignore`, `.rspec`,
`spec/spec_helper.rb`, `.ruby-version` (`4.0.5`), and an empty
`app/modules/.keep`.

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--path PATH` | string | (none) | Use a **local** shaolin checkout — generates `Gemfile.local.erb` with `path:` pointing at `File.expand_path(PATH)/gems`, instead of the git-based `Gemfile.erb`. |

```bash
shaolin new billing
shaolin new billing --path ../shaolin    # develop against a local checkout
```

`Main#new(app)` translates the flag: `opts = options[:path] ? { "path" => options[:path] } : {}`.

---

## generate / g

`map "g" => :generate`, so `g` is an alias. `Main#generate(type, *args)`
dispatches on `type`; unknown types raise `unknown generator … (available: module, field)`.

Generators run with `destination_root = Dir.pwd` and write into the **current
directory** (verified by spec: `g module gadgets` produces
`app/modules/gadgets/...`).

### g module NAME

```
shaolin g module NAME [--es] [--crud] [--reactor]
```

`Generators::ModuleGenerator` scaffolds a bounded-context module under
`app/modules/<name>/`. **Default is plain CRUD**; event sourcing is opt-in.

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--es` | boolean | `false` | Event-sourced CQRS module: command, event, aggregate, command handler, projection, read model, query + handler, DTO, controller, read-model migration, `CONTRACT.md`, aggregate spec, request spec. |
| `--crud` | boolean | `false` | Plain ActiveRecord CRUD module (the default; kept for explicitness): `module.rb`, model, DTO, controller, migration, `CONTRACT.md`, request spec. |
| `--reactor` | boolean | `false` | Also scaffold an async `Reactor` + spec. **Requires `--es`.** |

Gotchas (raise `Thor::Error`):
- `pass either --es or --crud, not both` — if both flags given.
- `--reactor needs events; add --es (a CRUD module has none)` — `--reactor` without `--es`.

`name` is normalized via `Naming` (see below): `users` → namespace `Users`,
entity `User`, command `CreateUser`, event `UserCreated`, topic
`users.user_created`, read table `users_read`. Acronyms are inflector-aware
(`url_maps` → `URLMaps`). Migration **class** names use plain
segment-capitalize (`create_api_keys_read` → `CreateApiKeysRead`) to match
ActiveRecord's filename→constant rule, not the acronym-aware namespace.

Migration filenames get a unique, monotonically-bumped timestamp
(`%Y%m%d%H%M%S`, `+= 1` until unique across `app/modules/*/db/migrate/*.rb`) so
two modules generated in the same second don't collide.

```bash
shaolin g module products            # CRUD (default)
shaolin g module orders --es         # event-sourced CQRS
shaolin g module orders --es --reactor   # CQRS + async reactor
```

```ruby
# programmatic use (what the spec does)
gen = Shaolin::CLI::Generators::ModuleGenerator.new(["orders"], { "es" => true })
gen.destination_root = Dir.pwd
gen.invoke_all
```

### g field MODULE name:type

```
shaolin g field MODULE NAME:TYPE
```

`Generators::FieldGenerator` adds **only** the mechanical part — an
`add_column` migration — and prints a by-hand edit checklist. It deliberately
does **not** rewrite existing Ruby.

- `MODULE` — plural module name (e.g. `orders`).
- `NAME:TYPE` — `field_spec` split on the first `:`. **Type defaults to `string`** when omitted or empty (`g field articles slug` → `:string`).
- Target table is chosen by detecting `app/modules/<mod>/events`: an **ES** module targets the **read table** (`orders_read`); a CRUD module targets the table itself (`articles`).
- Missing `MODULE` or `NAME:TYPE` raises `usage: shaolin g field MODULE name:type`.

```bash
shaolin g field articles views:integer   # -> add_column :articles, :views, :integer
shaolin g field orders amount:integer     # ES -> add_column :orders_read, :amount, :integer
shaolin g field articles slug             # type defaults to :string
```

The checklist (printed in yellow) points at the files you must still edit —
command/event/DTO/aggregate/projection for ES, or DTO/controller for CRUD.

---

## server

```
shaolin server
```

Boots the app, then `require "shaolin/server"` and runs
`Shaolin::Server.run(Shaolin::Kernel["http.app"])`.

Gotcha (Falcon fiber isolation): if `Shaolin::AR` is defined **and** the
configured adapter is `:falcon`, the CLI sets
`Shaolin::AR::Connection.isolation_level = :fiber` before serving, because
Falcon is fiber-per-request and AR connections must be isolated per fiber.

Configured from ENV via `Shaolin::Server::Config.new(env: ENV)`:

| ENV | Default | Meaning |
|---|---|---|
| `HOST` | `0.0.0.0` | Bind host |
| `PORT` | `8080` | Bind port (cast via `Integer`) |
| `SHAOLIN_SERVER` | `falcon` | Adapter (`:falcon` default; `puma` opt-in) |
| `SHAOLIN_GRACEFUL_TIMEOUT` | `10` | Graceful shutdown seconds |
| `SHAOLIN_REQUEST_TIMEOUT` | (off) | Per-request deadline (seconds, `Float`); Falcon-enforced |

```bash
PORT=3000 SHAOLIN_SERVER=puma shaolin server
```

---

## console

```
shaolin console
```

Boots the app, `require "irb"`, then `IRB.start`. A REPL with the kernel,
modules, and DB wired up.

```bash
shaolin console
# irb> Shaolin::Kernel["cqrs.command_bus"]
```

---

## migrate

```
shaolin migrate
```

The release step. Boots the app and runs the private `apply_schema!`:

```ruby
require "shaolin/activerecord"
Shaolin::AR::EventStoreSchema.create!                       # event store tables
Shaolin::AR::Migrator.run(File.join(Dir.pwd, "app/modules"))  # read-model migrations
Shaolin::Jobs::Schema.create! if defined?(Shaolin::Jobs::Schema) # outbox/jobs tables
```

Idempotent — prints `schema up to date` on success. `Migrator.run(modules_dir)`
applies every `app/modules/*/db/migrate/*.rb`.

```bash
shaolin migrate   # run on deploy / release
```

---

## db

```
shaolin db [ACTION]    # ACTION defaults to "reset"
```

Only `reset` is supported; anything else raises
`unknown db action … (available: reset)`.

**DEV ONLY.** Refuses to run when `SHAOLIN_ENV=production`
(`refusing to db reset with SHAOLIN_ENV=production`).

`db reset` boots the app, then via a maintenance connection to the `postgres`
database (`recreate_database!`):
1. `clear_all_connections!`
2. `DROP DATABASE IF EXISTS "<name>" WITH (FORCE)` (terminates open connections)
3. `CREATE DATABASE "<name>"`
4. re-establishes the app connection and runs `apply_schema!`

Prints `db reset: dropped + recreated + migrated <name>`.

```bash
shaolin db          # == shaolin db reset
shaolin db reset
```

| ENV | Effect |
|---|---|
| `SHAOLIN_ENV=production` | Hard refusal (guard rail) |

---

## rollback

```
shaolin rollback [STEPS]    # STEPS defaults to "1"
```

Rolls back the last `STEPS` read-model migrations:

```ruby
Shaolin::AR::Migrator.rollback(File.join(Dir.pwd, "app/modules"), Integer(steps))
```

`STEPS` is parsed with `Integer()` (strict — a non-numeric arg raises). Prints
`rolled back N migration(s)`. Does **not** touch the event-store or jobs schema.

```bash
shaolin rollback        # last 1
shaolin rollback 3      # last 3
```

---

## worker

```
shaolin worker
```

Runs the jobs worker, draining the transactional outbox (delivers events to
async reactors). Boots the app, `require "shaolin/jobs"`, then:

```ruby
Shaolin::Jobs::Worker.new(
  event_store: Shaolin::Kernel["cqrs.event_store"],
  batch:       batch,
  tx_per_job:  tx_per_job
).run(threads: threads)
```

Tuned entirely by ENV:

| ENV | Default | Cast | Meaning |
|---|---|---|---|
| `WORKER_CONCURRENCY` | `1` | `Integer` | Worker thread count (`run(threads:)`) |
| `WORKER_BATCH` | `20` | `Integer` | Jobs drained per batch (`batch:`) |
| `WORKER_TX_PER_JOB` | (false) | `"1"`/`"true"` | One transaction per job — IO-bound mode; otherwise batch-tx |

Gotcha: if `WORKER_CONCURRENCY` exceeds the AR connection-pool size
(`ActiveRecord::Base.connection_pool.size`), it warns
`set DB_POOL>=N to avoid connection timeouts` (yellow) but still starts. The
startup line reports threads, batch, mode (`tx-per-job (IO-bound)` or
`batch-tx`), and DB pool.

`Worker#run(poll_interval: 0.5, threads: 1)` runs a fixed thread pool with a
graceful SIGTERM/INT stop. `Worker#run_once(now: Time.now)` drains one batch and
returns the count.

```bash
WORKER_CONCURRENCY=4 WORKER_BATCH=50 DB_POOL=8 shaolin worker
WORKER_TX_PER_JOB=1 shaolin worker      # IO-bound reactors
```

The full constructor (for tests/embedding):

```ruby
Shaolin::Jobs::Worker.new(
  event_store:,
  outbox:        Shaolin::Jobs::Outbox.new,
  batch:         20,
  tx_per_job:    false,
  backoff:       Shaolin::Jobs::Outbox::DEFAULT_BACKOFF,
  max_attempts:  Shaolin::Jobs::Outbox::DEFAULT_BACKOFF.size,
  listen:        true,
  prefer_payload: false
)
```

---

## scheduler

```
shaolin scheduler
```

Runs the periodic-task scheduler. Boots the app, `require "shaolin/jobs"`, then
`Shaolin::Jobs::Scheduler.new.run`. A single leader is enforced via a Postgres
advisory lock, so it's safe to run several replicas. Schedules are declared with
`Shaolin.schedule("name", every: "5m") { … }`.

`Scheduler#new(schedules: Schedules)` and `Scheduler#run(interval: 1.0)`.

```bash
shaolin scheduler
```

---

## jobs

```
shaolin jobs [ACTION] [ID]   # ACTION defaults to "stats"
```

Inspect the outbox via `Shaolin::Jobs::Outbox.new`.

| ACTION | Behavior |
|---|---|
| `stats` (default) | Prints counts per status — `pending`, `failed`, `done`, `dead` (from `outbox.stats`, which is `OutboxJob.group(:status).count`). Missing statuses show `0`. |
| `dead` | Lists dead-lettered jobs (`outbox.dead`, newest first, limit 50) as `id\treactor\tevent_type\tlast_error` (red); prints `no dead-lettered jobs` (green) if empty. |
| `retry ID` | Re-queues dead job `ID` (`outbox.retry!(id)` → `pending`, `attempts: 0`). Prints `re-queued job ID` if a row changed, else `no dead job ID`. Missing `ID` raises `usage: shaolin jobs retry ID`. |

Unknown action raises `unknown action … (stats | dead | retry ID)`.

```bash
shaolin jobs              # == shaolin jobs stats
shaolin jobs dead
shaolin jobs retry 42
```

---

## projections

```
shaolin projections rebuild [NAME]
```

Only `rebuild` is supported (else `unknown action … (available: rebuild)`).
Boots the app, `require "shaolin/cqrs"`, then:

```ruby
Shaolin::CQRS::ProjectionRunner.rebuild_all(only: name)   # name = NAME or nil
```

Replays the event store into read models. With `NAME`, rebuilds only the named
projection (`only:`); without it, all. Prints `projections rebuilt` (plus
`for NAME` when scoped).

```bash
shaolin projections rebuild          # all projections
shaolin projections rebuild orders   # just one
```

---

## describe

```
shaolin describe [--json]
```

Prints a machine-readable map of the app built from module **manifests** —
**no boot, no DB** (`Describe.map("app/modules")`). Each `module.rb` is
`require`d after `Shaolin::Registry.reset!`.

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--json` | boolean | `false` | Emit `JSON.pretty_generate` (for agents/tools) instead of the colored human listing. |

The JSON map shape:

```jsonc
{
  "ruby": "4.0.5",
  "modules": [{
    "name", "imports", "exports",
    "commands_handled", "events_published", "events_subscribed",
    "reactors": [{ "class", "on": [...], "topics": [...], "file" }]
  }],
  "scheduled": [{ "name", "every" }],
  "harnesses": [{ "name", "model", "gates": [...] }]
}
```

Reactors, schedules, and harnesses are extracted by **static Prism analysis**
(`StaticScan`): `on(Const)` → `on:`, `on("topic")` → `topics:`,
`Shaolin.schedule("…", every: "…")` → `scheduled`. Harnesses load from
`app/harnesses/**` and `app/modules/*/harnesses/**`; absent
`shaolin-harness`, the list is empty.

The human listing prints per module: `command:`, `event:`, `import:`,
`export:`, `subscribes:`, and `reactor: <Class> on <subs>`, plus
`scheduled:` and `harness:`/`gate:` lines.

```bash
shaolin describe
shaolin describe --json | jq '.modules[].name'
```

```ruby
Shaolin::CLI::Describe.map(File.join(Dir.pwd, "app/modules"))
```

---

## schemas

```
shaolin schemas [--json]
```

Prints just the command/event surface — **always JSON**
(`JSON.pretty_generate(Describe.schemas("app/modules"))`); the `--json` flag is
accepted (default `false`) but output is JSON regardless. No boot.

```jsonc
[{ "name": "orders", "commands": ["Orders::Commands::CreateOrder"], "events": ["orders.order_created"] }]
```

```bash
shaolin schemas | jq '.[] | {name, commands}'
```

```ruby
Shaolin::CLI::Describe.schemas(File.join(Dir.pwd, "app/modules"))
```

---

## openapi

```
shaolin openapi [--out FILE]
```

Generates an OpenAPI **3.1** document. Boots the app (paths come from booted
controllers; request schemas from DTOs), `require "shaolin/http"`, then:

```ruby
Shaolin::HTTP::OpenAPI.generate(Shaolin::Kernel["kernel.containers"], File.join(Dir.pwd, "app/modules"))
```

(`OpenAPI.generate(containers, modules_dir, title: "API")`.)

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--out FILE` | string | stdout | Write the pretty JSON to `FILE` (prints `wrote FILE`); otherwise print to stdout. |

```bash
shaolin openapi                       # to stdout
shaolin openapi --out openapi.json    # to a file
```

---

## lint

```
shaolin lint [--strict]
```

Static module-isolation check (Prism, **no boot**) via `Isolation.new("app/modules")`.
Requires `app/modules` (else `no app/modules in <dir>`).

Two finding classes:

- **Module-internal violations** (`iso.violations`) — **always hard errors**:
  - `cross-module-reference` — references another module's top-level namespace constant (use imports/exports).
  - `require-escapes-module` — `require_relative` resolving outside the module's own folder.
  - `undeclared-import` — `import("key")` not declared in `module.rb` (add `imports "key"`).
- **Outside-the-graph findings** (`iso.outside_violations(Dir.pwd)`) — code under `app/` but outside `app/modules` (skipping `config bin spec test vendor tmp .bundle .git node_modules`). **Warn by default, fail with `--strict`**:
  - `kernel-internal-access` — reads `Shaolin::Kernel` internals from outside a module.
  - `outside-module-reference` — references a module namespace from outside the module graph.

| Flag / ENV | Default | Effect |
|---|---|---|
| `--strict` | `false` | Promote outside-graph findings to failures. |
| `SHAOLIN_LINT_STRICT=1` | (unset) | Same as `--strict`. |

Output: violations in red, outside findings in yellow (`(warning)` suffix
unless strict). Exit semantics — `failures = violations.size + (strict ? outside.size : 0)`;
non-zero raises `N isolation violation(s)`. Clean run prints
`isolation OK — modules are self-contained` (or `no module-isolation violations`
when only non-strict warnings exist).

```bash
shaolin lint
shaolin lint --strict          # fail CI on non-module reach-ins
SHAOLIN_LINT_STRICT=1 shaolin lint
```

---

## graph

```
shaolin graph
```

Prints the module dependency graph from manifests. Does **not** call
`boot_app!`; instead `require "shaolin/core"`, `Shaolin::Registry.reset!`, then
`require`s each `app/modules/*/module.rb`.

Per module it prints (cyan name):
- `imports:    <key>` for each `mod.imports`
- `publishes:  <event>` for each `mod.events_published`
- `<mod> -> <owner>  (consumes <event>)` for each `mod.subscribed_events`, where the owner is `Shaolin::Topic.module_name(event)` — a B→A edge.

Then harness edges (magenta) from `Describe.harnesses("app")`: `<gate> -> <to>`
for each gate target, and `<gate> (terminal)` for terminal gates with no edges.

```bash
shaolin graph
```

---

## routes

```
shaolin routes
```

Boots the app and lists, per module (from `Shaolin::Registry.all`), the
`command:` and `event:` surface (`mod.commands_handled`, `mod.events_published`).
Unlike `describe`/`schemas`, this reads the **booted** registry rather than
parsing manifests.

```bash
shaolin routes
```

---

## Supporting modules

These are internal to `shaolin-cli` but documented because generator output and
lint depend on them.

### Shaolin::CLI::Naming

`module_function` inflection helpers (single source of name conventions; uses
the shared acronym-aware `Shaolin::Inflector`). All take the raw module `name`.

| Method | Example (`"users"`) | Notes |
|---|---|---|
| `namespace(name)` | `"Users"` | Camelized namespace |
| `entity(name)` | `"User"` | Singular, camelized |
| `entity_us(name)` | `"user"` | Singular, underscored |
| `module_us(name)` | `"users"` | Underscored module name |
| `read_table(name)` | `"users_read"` | ES read-model table |
| `command(name)` | `"CreateUser"` | |
| `command_us(name)` | `"create_user"` | |
| `event(name)` | `"UserCreated"` | |
| `event_us(name)` | `"user_created"` | |
| `topic(name)` | `"users.user_created"` | |
| `migration_class(stem)` | `migration_class("create_users_read") => "CreateUsersRead"` | **Plain** segment-capitalize (no acronym uppercasing) to match ActiveRecord's filename→constant rule. |

```ruby
Shaolin::CLI::Naming.topic("url_maps")          # => "url_maps.url_map_created"
Shaolin::CLI::Naming.namespace("url_maps")      # => "URLMaps" (acronym-aware)
Shaolin::CLI::Naming.migration_class("create_api_keys_read") # => "CreateApiKeysRead"
```

### Shaolin::CLI::Describe

`module_function`s consumed by `describe`/`schemas`/`graph`.

| Method | Signature | Purpose |
|---|---|---|
| `map` | `map(modules_dir)` | Full app map (resets registry, requires every `module.rb`, runs `StaticScan` + harnesses). |
| `harnesses` | `harnesses(app_root)` | Gate/tool/model maps from `app/harnesses/**` + `app/modules/*/harnesses/**`; `[]` if `shaolin-harness` absent. |
| `module_map` | `module_map(mod, modules_dir)` | One module's `{name, imports, exports, commands_handled, events_published, events_subscribed, reactors}`. |
| `schemas` | `schemas(modules_dir)` | `{name, commands, events}` per module. |

```ruby
require "shaolin/cli/describe"
Shaolin::CLI::Describe.map("app/modules")[:modules].map { _1[:name] }
```

### Shaolin::CLI::StaticScan

Boot-free Prism extraction of the async surface.

| Method | Signature | Returns |
|---|---|---|
| `reactors` | `reactors(module_dir)` | `[{ class:, on: [consts], topics: [strings], file: }]` from `reactors/*.rb` (any class with `on(...)`). |
| `schedules` | `schedules(*roots)` | `[{ name:, every: }]` from `Shaolin.schedule("name", every: "5m")` calls under each root. |

```ruby
Shaolin::CLI::StaticScan.reactors("app/modules/signups")
# => [{ class: "NotifyReactor", on: ["Signups::Events::SignupCompleted"], topics: [], file: "notify_reactor.rb" }]
```

### Shaolin::CLI::Isolation

`Isolation.new(modules_dir)`. Drives `lint`.

| Method | Signature | Purpose |
|---|---|---|
| `violations` | `violations` | Module-internal findings (always errors). |
| `outside_violations` | `outside_violations(app_root)` | Findings outside the module graph (warn / `--strict` fail). |

Returns `Violation` structs (`Struct.new(:file, :line, :rule, :message)`);
`#to_s` → `"file:line  rule: message"`. `EXEMPT_DIRS = %w[config bin spec test
vendor tmp .bundle .git node_modules]`.

```ruby
require "shaolin/cli/isolation"
iso = Shaolin::CLI::Isolation.new(File.join(Dir.pwd, "app/modules"))
iso.violations.each { |v| puts v }            # hard errors
iso.outside_violations(Dir.pwd).each { |v| puts v }  # warnings
```

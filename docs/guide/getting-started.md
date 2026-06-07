# Getting started

> Grounded in the code under `gems/shaolin-cli/` (CLI + generators + templates), with cross-references
> to the providers in `gems/shaolin-{core,activerecord,cqrs,http,server}/`. This page takes you from an
> empty directory to a first end-to-end HTTP request.

shaolin is a standalone, modular **CQRS / Event-Sourcing** backend framework for Ruby 4.0+ — not Rails,
but Rails-ecosystem gems (ActiveRecord first) work. It is distributed as a single private-git umbrella
gem and operated through the `shaolin` CLI.

---

## 1. Install (from private git)

shaolin is **not on RubyGems**. One line in an app's `Gemfile` pulls the whole framework. Bundler's
`glob:` exposes every sub-gem's gemspec in the repo, so the umbrella `shaolin` resolves all components
(`core`, `cqrs`, `activerecord`, `dto`, `http`, `server`, `jobs`, `messaging`, `redis`, `rabbitmq`,
`llm`, `harness`, and the `shaolin` CLI). You need read access to the repo.

```ruby
# Gemfile
source "https://rubygems.org"

gem "shaolin", git: "git@github.com:mantissa-lab/shaolin.git", glob: "gems/*/*.gemspec"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rack-test"
end
```

```ruby
# config/boot.rb
require "shaolin" # umbrella: loads core, cqrs, activerecord, dto, http, server, jobs, …
```

Pin a `tag:`/`branch:` (e.g. `tag: "v0.1.0"`) for reproducible builds. For local framework development,
`shaolin new --path <checkout>` generates the same single line with `path:` instead of `git:`:

```ruby
gem "shaolin", path: "/abs/path/to/shaolin", glob: "gems/*/*.gemspec"
```

> Gotcha: the private repo requires an SSH key (or swap to the https URL + a token). `glob:` is what
> makes the one-liner resolve every sub-gem — omit it and Bundler only sees the umbrella gemspec.

`shaolin new` writes all of this for you; you rarely hand-author the `Gemfile`.

---

## 2. The `shaolin` CLI

The executable (`exe/shaolin`) is a [Thor](https://github.com/rails/thor) app, `Shaolin::CLI::Main`.
`self.exit_on_failure? == true`, so a `Thor::Error` exits non-zero. Run commands from the app root
(most call the private `boot_app!`, which requires `config/boot.rb` and errors if it is missing).

| Command | Purpose | Options / args |
|---|---|---|
| `shaolin new APP` | Scaffold a runnable app. | `--path PATH` → local-checkout Gemfile (`path:`) |
| `shaolin generate TYPE …` (alias `g`) | Generate code. `TYPE` = `module` or `field`. | `--es`, `--crud`, `--reactor` (module only) |
| `shaolin server` | Boot the app and serve HTTP (Falcon by default). | — |
| `shaolin console` | Boot the app and open IRB. | — |
| `shaolin migrate` | Release step: event-store schema + jobs schema + read-model migrations. | — |
| `shaolin db ACTION` | `ACTION=reset` (default): drop + create + migrate. **Dev only.** | refuses if `SHAOLIN_ENV=production` |
| `shaolin rollback [STEPS]` | Roll back the last `STEPS` read-model migrations. | `STEPS` (default `"1"`) |
| `shaolin worker` | Process the outbox (run async reactors). | env: `WORKER_CONCURRENCY`, `WORKER_BATCH`, `WORKER_TX_PER_JOB` |
| `shaolin scheduler` | Fire periodic `Shaolin.schedule` tasks (single leader via advisory lock). | — |
| `shaolin jobs [ACTION] [ID]` | Inspect the outbox. `ACTION` = `stats` (default), `dead`, `retry ID`. | `ID` (for `retry`) |
| `shaolin projections ACTION [NAME]` | `ACTION=rebuild`: replay events into read models. | `NAME` limits to one projection |
| `shaolin describe` | Machine-readable map of modules (commands, events, imports, exports, reactors, harnesses). | `--json` |
| `shaolin schemas` | Each module's command/event surface (always JSON). | `--json` (no-op; always JSON) |
| `shaolin openapi` | OpenAPI 3.1 doc (paths from controllers, request schemas from DTOs). | `--out FILE` (default stdout) |
| `shaolin lint` | Module-isolation check (Prism static analysis). | `--strict` (or `SHAOLIN_LINT_STRICT=1`) |
| `shaolin graph` | Module dependency graph (imports + events) from manifests. | — |
| `shaolin routes` | List modules and the commands/events they expose. | — |

### `shaolin new APP`

`Main#new(app)` → `Generators::NewAppGenerator`. The `--path` flag passes a `"path"` option through to
the generator (otherwise the option hash is empty).

```bash
shaolin new shop                    # git-based Gemfile
shaolin new shop --path ~/dev/shaolin   # local-path Gemfile (framework dev)
```

`NewAppGenerator` (a `Thor::Group`) takes one argument `name` and class option `--path` (default `nil`).
It derives two names via `Shaolin::CLI::Naming`:

| Var | From | Example (`shop`) |
|---|---|---|
| `@app` | `Naming.module_us(name)` (underscore) | `shop` |
| `@app_class` | `Naming.namespace(name)` (camelize) | `Shop` |
| `@local_path` | `File.expand_path(--path)` or `nil` | — |

It then renders the templates below into `./<@app>/` (and `chmod 0o755 bin/server`):

```
shop/
├── Gemfile                  # git or path: build (one line + rspec/rack-test)
├── .ruby-version            # "4.0.5"
├── .env.example             # PORT, SHAOLIN_SERVER, DB_* (see §4)
├── .dockerignore
├── .rspec                   # --require spec_helper --format documentation
├── Dockerfile
├── README.md
├── AGENTS.md                # agent guide: conventions, flow, rules
├── config/boot.rb           # composition root (see §3)
├── bin/server               # require boot + Shaolin::Server.run(Kernel["http.app"])
├── deploy/service.yaml      # Knative / Cloud Run manifest
├── spec/spec_helper.rb      # SHAOLIN_SKIP_BOOT, boot_app!, Shaolin::Testing.install
└── app/modules/.keep        # your modules live here
```

### `shaolin g module NAME`

`Main#generate("module", NAME, …)` → `Generators::ModuleGenerator`. `NAME` should be **plural**
(`orders`). Default output is a **plain CRUD** module; `--es` produces an event-sourced CQRS module.

```bash
shaolin g module orders            # CRUD (ActiveRecord model + DTO + controller + migration)
shaolin g module orders --es       # event-sourced CQRS (command/event/aggregate/projection/…)
shaolin g module orders --es --reactor   # also an async reactor + spec
```

Flags (validated in `ModuleGenerator#create_module`):

| Flag | Default | Notes |
|---|---|---|
| `--es` | `false` | Event-sourced CQRS module. |
| `--crud` | `false` | Plain CRUD (the default; kept for explicitness). |
| `--reactor` | `false` | Also scaffold a reactor + spec. **Requires `--es`.** |

Gotchas (raise `Thor::Error`): passing both `--es` and `--crud`; passing `--reactor` without `--es`
("a CRUD module has none [events]").

**Inflection** (`Shaolin::CLI::Naming`, backed by the shared acronym-aware `Shaolin::Inflector`), for
`orders`:

| Helper | Result |
|---|---|
| `namespace` | `Orders` |
| `entity` / `entity_us` | `Order` / `order` |
| `module_us` | `orders` |
| `command` / `command_us` | `CreateOrder` / `create_order` |
| `event` / `event_us` | `OrderCreated` / `order_created` |
| `topic` | `orders.order_created` |
| `read_table` | `orders_read` |
| `migration_class(stem)` | segment-capitalize (matches AR's filename→constant rule, **no** acronyms) |

Migration versions come from `migration_timestamp` — `Time.now.strftime("%Y%m%d%H%M%S")`, bumped +1
past any existing migration so two modules generated in the same second don't collide.

**Generated CRUD module** (`app/modules/orders/`): `module.rb` (empty manifest), `order.rb`
(`< Shaolin::AR::ReadModel`, `self.table_name = "orders"`), `dto/order_dto.rb`,
`controllers/orders_controller.rb` (index/create/show/update/destroy), `db/migrate/<ts>_create_orders.rb`
(`create_table(:orders)` with `t.string :name; t.timestamps`, default bigint `id`), `CONTRACT.md`, and
`spec/requests/orders_spec.rb`.

**Generated `--es` module** adds the full CQRS anatomy: `commands/create_order.rb`
(`< Shaolin::ValueObject`), `events/order_created.rb` (`< RubyEventStore::Event`), `order.rb`
(`include Shaolin::CQRS::Aggregate`), `command_handlers/create_order_handler.rb`
(`< Shaolin::CQRS::CommandHandler`), `read_models/order_record.rb` (`< Shaolin::AR::ReadModel`,
table `orders_read`), `projections/orders_projection.rb` (`< Shaolin::CQRS::Projection`),
`queries/find_order.rb`, `query_handlers/find_order_handler.rb` (`< Shaolin::CQRS::QueryHandler`),
`dto/create_order_dto.rb`, `controllers/orders_controller.rb`, the `<ts>_create_orders_read.rb`
migration (`create_table(:orders_read, id: :string)`), `CONTRACT.md`, plus `spec/order_spec.rb` and
`spec/requests/orders_spec.rb`. With `--reactor`: `reactors/order_reactor.rb` +
`spec/reactors/order_reactor_spec.rb`.

### `shaolin g field MODULE name:type`

`Generators::FieldGenerator` — args `module_name` (plural) and `field_spec` (`name:type`; type
defaults to `string` if omitted). It generates **only** the `add_column` migration (version-bumped) and
prints a manual edit checklist; it deliberately does not rewrite your command/event/aggregate/DTO.

```bash
shaolin g field orders amount:integer
```

It auto-detects ES vs CRUD by the presence of `app/modules/<module>/events/` and targets the
`orders_read` table (ES) or the `orders` table (CRUD) accordingly. The checklist differs by kind:

- **ES**: edit `commands/create_order.rb`, `events/order_created.rb`, `dto/create_order_dto.rb`,
  `order.rb` (aggregate `apply`), `projections/*_projection.rb`.
- **CRUD**: edit `dto/order_dto.rb`, `controllers/orders_controller.rb`.

---

## 3. Dev-vs-prod boot (`config/boot.rb` + `SHAOLIN_ENV`)

The generated `config/boot.rb` is the composition root. It defines a constant `PRODUCTION` from the
**`SHAOLIN_ENV`** env var and registers providers, then boots `Shaolin::App`:

```ruby
require "shaolin"

module Shop
  ROOT = File.expand_path("..", __dir__)

  DATABASE = {
    adapter:  "postgresql",
    database: ENV.fetch("DB_NAME", "shop_development"),
    username: ENV.fetch("DB_USER", "postgres"),
    host:     ENV.fetch("DB_HOST", "localhost"),
    port:     Integer(ENV.fetch("DB_PORT", "5432"))
  }.freeze

  PRODUCTION = ENV["SHAOLIN_ENV"] == "production"

  def self.boot!
    Shaolin::AR.register_provider!(config: DATABASE, auto_schema: !PRODUCTION)
    Shaolin::CQRS.register_provider!
    Shaolin::HTTP.register_provider!(swagger: !PRODUCTION, modules_dir: File.join(ROOT, "app/modules"))
    app = Shaolin::App.new(root: ROOT).boot!
    migrate! unless PRODUCTION
    app
  end

  def self.migrate!
    Shaolin::AR::EventStoreSchema.create!
    Shaolin::AR::Migrator.run(File.join(ROOT, "app/modules"))
  end
end

Shop.boot! unless ENV["SHAOLIN_SKIP_BOOT"]
```

What `SHAOLIN_ENV=production` changes (everything keys off `PRODUCTION`):

| Concern | Dev (default) | `SHAOLIN_ENV=production` |
|---|---|---|
| Event-store schema | `auto_schema: true` (created at boot, advisory-locked) | `auto_schema: false` → run `shaolin migrate` |
| Read-model migrations | `migrate!` runs on every boot | skipped → run `shaolin migrate` |
| Swagger UI / `/openapi.json` | on (`swagger: true`) | off |
| `shaolin db reset` | allowed | **refused** (raises `Thor::Error`) |

The provider signatures these calls hit:

- `Shaolin::AR.register_provider!(config:, isolation_level: :thread, auto_schema: true, replica_config: nil)`
  — connects, optionally creates the event-store schema, publishes `cqrs.event_store_backend` +
  `cqrs.transaction`. Register **before** `:cqrs`.
- `Shaolin::CQRS.register_provider!` — builds `cqrs.event_store`, `cqrs.command_bus`, `cqrs.query_bus`,
  `cqrs.aggregate_repository`; auto-wires module handlers + projections. Uses the AR backend if present,
  else an in-memory store.
- `Shaolin::HTTP.register_provider!(middleware: [], swagger: false, modules_dir: nil, auth: {}, max_concurrency: nil)`
  — assembles the Rack app from controllers and publishes `http.app`. Register **after** `:cqrs`.
- `Shaolin::App.new(root:, env: ENV).boot!` — composition root; `#boot!` runs the lifecycle and returns
  `self`. Also `#shutdown!`, `#modules`, `#[](name)` (a module's isolation-enforcing container).

`Shaolin::Kernel["<key>"]` fetches a registered component (e.g. `Shaolin::Kernel["http.app"]`,
`["cqrs.command_bus"]`); `Shaolin::Kernel.key?("<key>")` tests presence.

> Gotcha: `boot.rb` self-boots at require time **unless `SHAOLIN_SKIP_BOOT` is set**. The generated
> `spec/spec_helper.rb` sets `SHAOLIN_SKIP_BOOT ||= "1"` so unit specs load code without a DB; request
> specs tagged `:integration` call `boot_app!` (memoized) and use `Shaolin::Testing.install` to truncate
> read models / event store / outbox between examples.

---

## 4. The dev server (`shaolin server`) and ENV

`Main#server` calls `boot_app!`, requires `shaolin/server`, sets AR connection isolation to `:fiber`
when the adapter is Falcon (fiber-per-request), then runs `Shaolin::Server.run(Shaolin::Kernel["http.app"])`.

`Shaolin::Server.run(rack_app, config: Config.new, adapter: nil)` builds the adapter from
`config.adapter`, logs a startup banner, installs SIGTERM/SIGINT traps for graceful shutdown, then
blocks. `Shaolin::Server::Config.new(env: ENV)` reads:

| ENV var | Default | Meaning |
|---|---|---|
| `HOST` | `0.0.0.0` | Bind address. |
| `PORT` | `8080` | Port. |
| `SHAOLIN_SERVER` | `falcon` | Adapter (`falcon` or `puma`). |
| `SHAOLIN_GRACEFUL_TIMEOUT` | `10` | Shutdown window (seconds). |
| `SHAOLIN_REQUEST_TIMEOUT` | unset (off) | Per-request deadline, seconds (Falcon only). |

Other ENV vars seen at boot/run: `SHAOLIN_ENV` (`development` in the banner if unset), `DB_POOL`
(banner; default `5`), `SHAOLIN_WEB_CONCURRENCY` (web cap; banner shows `unbounded` if unset),
`SHAOLIN_LOG` / `SHAOLIN_LOG_EVERYTHING`, and the worker's `WORKER_CONCURRENCY` / `WORKER_BATCH` /
`WORKER_TX_PER_JOB`. The generated `.env.example`:

```
PORT=8080
SHAOLIN_SERVER=falcon
DB_NAME=shop_development
DB_USER=postgres
DB_HOST=localhost
DB_PORT=5432
```

`bin/server` is a thin equivalent of `shaolin server` (require boot, `Shaolin::Server.run(Shaolin::Kernel["http.app"])`).

---

## 5. First end-to-end request

This walks an **event-sourced** module (`--es`), the full CQRS/ES path. (Drop `--es` for the simpler
ActiveRecord CRUD flow — same HTTP shape, but the `id` is a bigint and there is no event store.)

```bash
shaolin new shop && cd shop
bundle install

# Postgres must be reachable per config/boot.rb's DATABASE (DB_NAME=shop_development by default).
bundle exec shaolin db reset          # dev: drop + create + migrate

bundle exec shaolin g module orders --es
bundle exec shaolin db reset          # pick up the new orders_read migration

bundle exec shaolin server            # Falcon on http://localhost:8080
```

The generated `Orders::Controllers::OrdersController` (`< Shaolin::HTTP::Controller`) wires the flow:

```ruby
routes do
  get  "/orders",     :index
  post "/orders",     :create
  get  "/orders/:id", :show
end

def create(req)
  dto = DTO::CreateOrderDTO.validate(req.params)     # dry-validation: required(:name).filled(:string)
  return unprocessable(dto.errors) if dto.failure?

  id = SecureRandom.uuid
  result = command_bus.call(Commands::CreateOrder.new(id: id, **dto.to_h))
  render_result(result, location: "/orders/#{id}")   # Success → 201 + Location
end

def show(req)
  record = query_bus.call(Queries::FindOrder.new(id: req[:id]))   # reads orders_read
  return not_found("order #{req[:id]} not found") unless record
  json({ id: record.id, name: record.name })
end
```

Flow: `POST` → DTO validation → `CreateOrder` command on the `command_bus` → `CreateOrderHandler`
runs `aggregate_repository.unit_of_work(Order.new(id)) { |o| o.create(name:) }` → the `Order`
aggregate `apply`s an `OrderCreated` event → it persists to the Postgres event store and, in the same
transaction, the `OrdersProjection` writes a row into `orders_read` → `GET /orders/:id` queries that
read model.

Drive it with curl:

```bash
curl -i -X POST localhost:8080/orders \
  -H 'content-type: application/json' \
  -d '{"name":"Widget"}'
# HTTP/1.1 201 Created
# Location: /orders/<uuid>
# {"id":"<uuid>","name":"Widget"}   (ES: id is the SecureRandom uuid)

curl localhost:8080/orders/<uuid>
# {"id":"<uuid>","name":"Widget"}

curl localhost:8080/orders
# [{"id":"<uuid>","name":"Widget"}]
```

A missing `name` returns `422` with `dto.errors`; an unknown id returns `404`. In dev, browse the live
docs at `GET /swagger` (and `GET /openapi.json`).

Controller helpers used above (`Shaolin::HTTP::Controller`): `command_bus`, `query_bus`, `event_store`
(kernel lookups); `json(data, status: 200, headers: {}, cookies: {})`; `created(data, location: nil)`;
`no_content`; `not_found(message = "not found")`; `unprocessable(details)`;
`render_result(result, location: nil)` (renders a `Dry::Monads` `Success`/`Failure`).

### Verify and inspect

```bash
bundle exec rspec                     # generated request + aggregate specs
bundle exec shaolin describe --json   # machine-readable map of all modules
bundle exec shaolin routes            # commands/events per module
bundle exec shaolin lint              # module-isolation check (use --strict to fail on outside-module findings)
bundle exec shaolin openapi --out openapi.json
```

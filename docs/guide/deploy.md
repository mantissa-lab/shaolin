# Deploy (Docker / Cloud Run / Knative)

> Grounded in the code: the templates under
> `gems/shaolin-cli/lib/shaolin/cli/templates/app/` (`Dockerfile.erb`, `deploy/service.yaml.erb`,
> `bin/server.erb`, `config/boot.rb.erb`, `env.example`, `dockerignore`) plus the runtime they
> drive — `Shaolin::Server`, `Shaolin::Jobs::{Worker,Scheduler}`, and the schema/migration
> modules in `shaolin-activerecord` / `shaolin-jobs`.

`shaolin new <app>` scaffolds a **container-native, GCP-first** deploy: one image, multiple
processes (web / worker / scheduler) off the same `bin/server` + `shaolin` CLI, schema applied as an
explicit **release step**, and graceful **SIGTERM** shutdown built into every long-running process.

---

## 1. The generated artifacts

`NewAppGenerator#create_app` renders (among others):

| Template | Renders to | Purpose |
| --- | --- | --- |
| `Dockerfile.erb` | `Dockerfile` | Two-stage `ruby:4.0-slim-bookworm` build; entrypoint = web server |
| `deploy/service.yaml.erb` | `deploy/service.yaml` | Knative `Service` (Cloud Run / Knative) for the HTTP process |
| `bin/server.erb` | `bin/server` (mode `0755`) | Web entrypoint: boot + `Shaolin::Server.run` |
| `config/boot.rb.erb` | `config/boot.rb` | Provider registration + `<App>.boot!` |
| `env.example` | `.env.example` | The 12-factor knobs (PORT, SHAOLIN_SERVER, DB_*) |
| `dockerignore` | `.dockerignore` | Keeps `.git`, `spec/`, `*.md`, `.env`, etc. out of the image |

### Dockerfile

```dockerfile
# syntax=docker/dockerfile:1
FROM ruby:4.0-slim-bookworm AS build
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential libpq-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without 'development test' && bundle install
COPY . .

FROM ruby:4.0-slim-bookworm AS runtime
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      libpq5 && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 shaolin
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
USER shaolin
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["bundle", "exec", "ruby", "bin/server"]
```

Notes / gotchas:

- **Multi-stage.** `build` carries `build-essential libpq-dev` (to compile the `pg` native ext);
  `runtime` only needs `libpq5`. The compiled bundle is copied from `/usr/local/bundle`.
- **Prod-only gems.** `bundle config set --local without 'development test'` — `rspec`/`rack-test`
  (the Gemfile's `:development, :test` group) are excluded from the image.
- **Non-root.** Runs as uid `1000` (`shaolin`). A read-only / non-root filesystem is fine; the app
  writes nothing at runtime by default.
- **`ENTRYPOINT` is the web process.** Override the command (not the entrypoint helper) to run a
  worker or scheduler — see §4. e.g. `docker run … bundle exec shaolin worker`.
- **`PORT=8080`** baked in; `bin/server` reads `PORT` via `Shaolin::Server::Config`.

### deploy/service.yaml (Knative `Service`)

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: <app>
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "0"
        autoscaling.knative.dev/maxScale: "10"
    spec:
      containerConcurrency: 100
      containers:
        - image: IMAGE_URL # set by CI (e.g. region-docker.pkg.dev/PROJECT/<app>)
          ports:
            - containerPort: 8080
          env:
            - name: DB_HOST
              value: "/cloudsql/PROJECT:REGION:INSTANCE"
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
```

| Field | Default | Meaning |
| --- | --- | --- |
| `minScale` | `"0"` | Scale to zero when idle (cold starts; boots are cheap because schema is *not* applied at boot in prod). |
| `maxScale` | `"10"` | Cap on replicas. |
| `containerConcurrency` | `100` | Concurrent requests per replica. Falcon is fiber-per-request, so this maps to in-flight fibers — keep `DB_POOL` in mind (§6). |
| `containerPort` | `8080` | Matches `EXPOSE 8080` / `PORT`. |
| `DB_HOST` | `/cloudsql/PROJECT:REGION:INSTANCE` | Cloud SQL unix socket. `boot.rb` reads `DB_HOST`. |
| `cpu` / `memory` | `1` / `512Mi` | Per-replica limits. |

`IMAGE_URL`, `PROJECT:REGION:INSTANCE` are placeholders your CI fills in. The manifest describes the
**HTTP process only** — worker and scheduler are separate deployments with the same image and a
different command (§4).

---

## 2. The boot model (`config/boot.rb`)

The generated `config/boot.rb` registers providers, then boots, branching on `SHAOLIN_ENV`:

```ruby
module MyApp
  ROOT = File.expand_path("..", __dir__)
  DATABASE = { adapter: "postgresql",
               database: ENV.fetch("DB_NAME", "myapp_development"),
               username: ENV.fetch("DB_USER", "postgres"),
               host: ENV.fetch("DB_HOST", "localhost"),
               port: Integer(ENV.fetch("DB_PORT", "5432")) }.freeze
  PRODUCTION = ENV["SHAOLIN_ENV"] == "production"

  def self.boot!
    Shaolin::AR.register_provider!(config: DATABASE, auto_schema: !PRODUCTION)
    Shaolin::CQRS.register_provider!
    Shaolin::HTTP.register_provider!(swagger: !PRODUCTION, modules_dir: File.join(ROOT, "app/modules"))
    app = Shaolin::App.new(root: ROOT).boot!
    migrate! unless PRODUCTION       # auto-migrate in dev only
    app
  end

  def self.migrate!
    Shaolin::AR::EventStoreSchema.create!
    Shaolin::AR::Migrator.run(File.join(ROOT, "app/modules"))
  end
end

MyApp.boot! unless ENV["SHAOLIN_SKIP_BOOT"]
```

The production split is deliberate: with `SHAOLIN_ENV=production`, `auto_schema: false` and
`migrate!` is skipped, so **no DDL runs on a pod boot** — boots stay fast and safe to scale to zero.
Schema becomes a release step (§3).

### `Shaolin::AR.register_provider!`

Registers the `:active_record` provider. **Register before `:cqrs`** (it publishes the event-store
backend the cqrs provider wraps).

```ruby
Shaolin::AR.register_provider!(config:, isolation_level: :thread, auto_schema: true, replica_config: nil)
```

| kwarg | default | purpose |
| --- | --- | --- |
| `config:` | — (required) | Plain AR config hash (`adapter`/`database`/`host`/…). Missing keys default from ENV (§6). |
| `isolation_level:` | `:thread` | AR connection isolation. `:fiber` under Falcon, `:thread` under Puma/worker. The web entrypoints set `:fiber` themselves when the adapter is falcon. |
| `auto_schema:` | `true` | Create the event-store schema at boot, under a Postgres advisory lock. **Set `false` in production** and run `shaolin migrate`. |
| `replica_config:` | `nil` | Optional read-replica config hash; opt into reads via `Shaolin::AR.reading { … }`. Writes (incl. the outbox) always hit the primary. |

The provider also registers a `database` readiness check (`Shaolin::Health`) and the
`cqrs.transaction` runner that makes the transactional outbox atomic.

### `Shaolin::HTTP.register_provider!`

```ruby
Shaolin::HTTP.register_provider!(swagger: !PRODUCTION, modules_dir: File.join(ROOT, "app/modules"))
```

`swagger:` mounts `/swagger` + `/openapi.json` (off in prod by default). The router always exposes
the probe endpoints (§5).

---

## 3. Migrations as a release step

Production never migrates on boot. Run **one** command as a release/deploy step, before flipping
traffic to the new revision:

```bash
SHAOLIN_ENV=production bundle exec shaolin migrate
```

`shaolin migrate` (`Main#migrate`) boots the app, then `apply_schema!` runs, in order:

1. `Shaolin::AR::EventStoreSchema.create!` — the RubyEventStore event-store tables.
2. `Shaolin::AR::Migrator.run("app/modules")` — per-module read-model migrations.
3. `Shaolin::Jobs::Schema.create!` (if `shaolin/jobs` is loaded) — the outbox + schedules tables.

All three are **idempotent** and safe to run on every deploy.

### `Shaolin::AR::EventStoreSchema`

```ruby
Shaolin::AR::EventStoreSchema.create!(data_type: "binary")  # idempotent; no-op if it already exists
Shaolin::AR::EventStoreSchema.exists?                        # => true/false (checks event_store_events)
Shaolin::AR::EventStoreSchema.drop!                          # drop both tables (dev)
```

| method | signature | purpose |
| --- | --- | --- |
| `create!` | `create!(data_type: "binary")` | Generate + run the RubyEventStore migration standalone (no Rails). `binary` round-trips symbol keys via the YAML serializer. |
| `drop!` | `drop!` | Drop `event_store_events_in_streams` + `event_store_events` (`force: :cascade`). |
| `exists?` | `exists?` | True if `event_store_events` exists. |

### `Shaolin::AR::Migrator`

Runs per-module read-model migrations from `app/modules/*/db/migrate/*.rb`. Each module owns its own
migrations.

```ruby
Shaolin::AR::Migrator.run(File.join(ROOT, "app/modules"))      # apply all pending, across modules
Shaolin::AR::Migrator.rollback(File.join(ROOT, "app/modules")) # roll back last 1
Shaolin::AR::Migrator.rollback(File.join(ROOT, "app/modules"), 3) # roll back last 3
```

| method | signature | purpose |
| --- | --- | --- |
| `run` | `run(modules_dir)` | Drift-check, then migrate every module's `db/migrate`. No-op if no migration dirs exist. |
| `rollback` | `rollback(modules_dir, steps = 1)` | Roll back the last `steps` applied migrations across all modules. |

**Drift detection (gotcha):** the SHA-256 of each applied file is stored in
`shaolin_migration_checksums`. If you edit a migration that is **already applied**, `run` raises
*before* migrating — because the edit would never reach a DB whose version is already in
`schema_migrations`. Fix: `shaolin db reset` in dev (re-applies from scratch), or in prod revert the
edit and add a **new** migration. Unapplied files are free to change.

### `Shaolin::Jobs::Schema`

```ruby
Shaolin::Jobs::Schema.create!  # idempotent; creates shaolin_jobs + shaolin_schedules
```

Creates the outbox (`shaolin_jobs`: a `(reactor, event_id)` unique index for idempotent enqueue, plus
a `(status, run_at)` claim index) and `shaolin_schedules`. Held under a Postgres advisory lock
(`7_283_011`) so concurrent replica boots can't race the create. In production this is reached via
`shaolin migrate`; the `:jobs` provider also calls it at boot.

### CLI release/ops commands

| command | what it does |
| --- | --- |
| `shaolin migrate` | The release step: event-store schema + read-model migrations + jobs schema. |
| `shaolin rollback [STEPS]` | `Migrator.rollback` the last `STEPS` (default 1) read-model migrations. |
| `shaolin db reset` | **DEV ONLY** — drop + recreate + migrate. Refuses to run with `SHAOLIN_ENV=production`. |
| `shaolin projections rebuild [NAME]` | Replay events into read models (`CQRS::ProjectionRunner.rebuild_all(only: NAME)`). |
| `shaolin jobs [stats\|dead\|retry ID]` | Inspect/operate the outbox (queue depth, dead letters, re-queue). |

---

## 4. Web vs worker vs scheduler — separate processes, one image

The same image runs three different long-lived process types. They differ only by the command. The
web entrypoint is `bin/server`; the others are `shaolin` CLI subcommands.

| Process | Command | Code path |
| --- | --- | --- |
| **web** | `bundle exec ruby bin/server` (Dockerfile entrypoint) | `Shaolin::Server.run(Kernel["http.app"])` |
| **worker** | `bundle exec shaolin worker` | `Shaolin::Jobs::Worker#run` (drains the outbox / runs reactors) |
| **scheduler** | `bundle exec shaolin scheduler` | `Shaolin::Jobs::Scheduler#run` (fires periodic tasks) |

On Cloud Run/Knative: the HTTP service uses `deploy/service.yaml`. The worker and scheduler are
separate deployments (e.g. a Cloud Run *job/service* or a k8s `Deployment`) running the same image
with the command overridden — for the worker, ideally `minScale: 1` (no scale-to-zero; it must keep
draining), and the scheduler is leader-elected (§4.3) so you can safely run more than one replica.

### 4.1 Web — `bin/server`

```ruby
#!/usr/bin/env ruby
require_relative "../config/boot"
require "shaolin/server"
Shaolin::Server.run(Shaolin::Kernel["http.app"])
```

`shaolin server` (the CLI equivalent) additionally sets `Shaolin::AR::Connection.isolation_level =
:fiber` when the adapter is falcon, so each fiber gets its own DB connection.

### 4.2 Worker — `shaolin worker`

`Main#worker` boots, then constructs and runs a worker:

```ruby
Shaolin::Jobs::Worker.new(
  event_store: Shaolin::Kernel["cqrs.event_store"],
  batch:       Integer(ENV.fetch("WORKER_BATCH", "20")),
  tx_per_job:  %w[1 true].include?(ENV["WORKER_TX_PER_JOB"])
).run(threads: Integer(ENV.fetch("WORKER_CONCURRENCY", "1")))
```

`Shaolin::Jobs::Worker.new`:

```ruby
Worker.new(event_store:, outbox: Outbox.new, batch: 20, tx_per_job: false,
           backoff: Outbox::DEFAULT_BACKOFF, max_attempts: Outbox::DEFAULT_BACKOFF.size,
           listen: true, prefer_payload: false)
```

| kwarg | default | purpose |
| --- | --- | --- |
| `event_store:` | — (required) | The shared event store (`Kernel["cqrs.event_store"]`); the worker reads the real event per job. |
| `outbox:` | `Outbox.new` | The outbox repository. |
| `batch:` | `20` | Max jobs a single `run_once` drains. ENV `WORKER_BATCH`. |
| `tx_per_job:` | `false` | `false` = whole batch in one tx (CPU-bound, fewer round-trips); `true` = each job its own short tx (IO-bound reactors hold a lock for just that job). ENV `WORKER_TX_PER_JOB` (`1`/`true`). |
| `backoff:` | `[1,10,60,600,3600]` (`Outbox::DEFAULT_BACKOFF`, seconds) | Retry delays per attempt. |
| `max_attempts:` | `5` (`DEFAULT_BACKOFF.size`) | After this many failures the job is dead-lettered (`status="dead"`). |
| `listen:` | `true` | When idle, wait on a Postgres `NOTIFY` (`shaolin_jobs` channel) for instant pickup; polling is the correctness floor. |
| `prefer_payload:` | `false` | Rebuild the event from the outbox row's YAML payload instead of reloading from the store (skips a round-trip; the store is canonical, so off by default). |

Methods:

| method | signature | purpose |
| --- | --- | --- |
| `run` | `run(poll_interval: 0.5, threads: 1)` | Long-running loop on a `threads`-sized pool; installs SIGTERM/INT traps; blocks until stopped, then drains in-flight work. ENV `WORKER_CONCURRENCY` → `threads`. |
| `run_once` | `run_once(now: Time.now)` | Drain up to `batch` due jobs; returns count processed. |
| `stop!` | `stop!` | Flip the stop flag (the trap calls this). |

```ruby
# One-shot drain (e.g. a test or a cron-style "process pending then exit"):
n = Shaolin::Jobs::Worker.new(event_store: Shaolin::Kernel["cqrs.event_store"]).run_once
```

Concurrency gotcha: `WORKER_CONCURRENCY` must be `<= DB_POOL`. The CLI warns
`WORKER_CONCURRENCY=N exceeds DB pool=P; set DB_POOL>=N` — otherwise threads time out checking out
connections. Multiple worker replicas are safe: jobs are claimed `FOR UPDATE SKIP LOCKED`, so no job
runs twice; a crash mid-process rolls the row back to `pending`.

### 4.3 Scheduler — `shaolin scheduler`

```ruby
Shaolin::Jobs::Scheduler.new.run
```

`Shaolin::Jobs::Scheduler`:

| member | signature | purpose |
| --- | --- | --- |
| `new` | `new(schedules: Schedules)` | Build a scheduler over the registered `Schedules`. |
| `run` | `run(interval: 1.0)` | TimerTask ticking every `interval`s; installs SIGTERM/INT traps; parks until shutdown. |
| `tick` | `tick(now: Time.now)` | Acquire the leader advisory lock, run due schedules, persist `last_run_at`; returns names fired (`[]` if not leader / nothing due). |
| `stop!` | `stop!` | Signal graceful shutdown (sets the stop flag + shutdown event). |

**Run as many replicas as you like:** a single leader is elected per tick via a Postgres advisory
lock (`ADVISORY_KEY = 7_283_001`), so a due task fires exactly once across all schedulers. A failing
task records its attempt first (so it respects its interval and can't hammer or abort the loop).

---

## 5. Health & observability endpoints

The HTTP router always mounts probes (use these in Knative `readinessProbe`/`livenessProbe` or the
Cloud Run health checks):

| Path | Behavior |
| --- | --- |
| `GET /healthz` | Liveness — static `200`. |
| `GET /readyz` | Readiness — runs all `Shaolin::Health` checks; `200 {"status":"ok",...}` or `503 {"status":"unavailable",...}`. |
| `GET /metrics` | Prometheus text exposition (`text/plain; version=0.0.4`). |
| `GET /openapi.json`, `/swagger` | Only when `swagger:` is on (dev default). |

`Shaolin::Health` is the readiness registry providers contribute to:

```ruby
Shaolin::Health.register("database") { Shaolin::AR::Connection.connected? }
ok, detail = Shaolin::Health.status  # => [true, { "database" => true, "redis" => true }]
```

| method | signature | purpose |
| --- | --- | --- |
| `register` | `register(name, &check)` | Add a named check; block returns truthy when the dependency is reachable. |
| `status` | `status` | `[overall_ok, { name => bool }]`; a raising check counts as not-ready. |
| `checks` / `reset!` | — | Inspect / clear the registry. |

### Logging

`Shaolin::Log` emits structured records; in production (`SHAOLIN_ENV=production`) the default sink is
`Sinks::Stdout` — **one JSON object per line to stdout**, which flows into Cloud Logging and can be
exported to BigQuery with zero app code. Dev uses the human-readable `Sinks::Pretty`.

```ruby
Shaolin::Log.emit(:info, "server.started", url: "http://0.0.0.0:8080", adapter: :falcon)
Shaolin::Log.info("deploy.note", revision: ENV["K_REVISION"])
```

Web/worker/scheduler each emit one structured startup line so you can confirm "did it start, where,
how is it bounded" (`server.started`, the worker/scheduler banners).

---

## 6. Graceful shutdown on SIGTERM

Cloud Run/Knative sends **SIGTERM** with a ~10s window before SIGKILL. Every long-running process
installs `TERM`/`INT` traps and shuts down cleanly.

### Web — `Shaolin::Server`

```ruby
Shaolin::Server.run(rack_app, config: Config.new, adapter: nil)
```

| method | signature | purpose |
| --- | --- | --- |
| `run` | `run(rack_app, config: Config.new, adapter: nil)` | Build the adapter, log the banner, install signal traps, then `adapter.start` (blocks). |
| `banner` | `banner(config)` | One structured `server.started` line (url, adapter, env, db_pool, web_concurrency, graceful_timeout). |
| `install_traps` | `install_traps(adapter, config)` | Trap `TERM`+`INT`; each fires `Thread.new { adapter.stop(timeout: config.graceful_timeout) }`. |

The trap spawns a thread (trap context is restricted) that calls `adapter.stop`, which unwinds the
blocking `start` so the process exits cleanly.

```ruby
# Custom adapter / explicit config:
cfg = Shaolin::Server::Config.new(env: { "PORT" => "9090", "SHAOLIN_SERVER" => "puma" })
Shaolin::Server.run(Shaolin::Kernel["http.app"], config: cfg)
```

**`Shaolin::Server::Config`** — 12-factor config from ENV:

```ruby
Shaolin::Server::Config.new(env: ENV)
# host, port, adapter, graceful_timeout, request_timeout
```

| reader | ENV | default | notes |
| --- | --- | --- | --- |
| `host` | `HOST` | `0.0.0.0` | |
| `port` | `PORT` | `8080` | |
| `adapter` | `SHAOLIN_SERVER` | `:falcon` | `:falcon` (async, default) or `:puma`. |
| `graceful_timeout` | `SHAOLIN_GRACEFUL_TIMEOUT` | `10` (seconds) | Passed to `adapter.stop(timeout:)`. |
| `request_timeout` | `SHAOLIN_REQUEST_TIMEOUT` | `nil` (off) | Per-request deadline; Falcon-only. |

**Adapters** (`Shaolin::Server::Adapters.build(name)` → `:falcon`/`:puma`, else raises
`Shaolin::Error`):

- `Falcon#start(rack_app, config)` runs the async reactor; `Falcon#stop(timeout: 10)` raises
  `Async::Stop` in the reactor thread so `start` returns. A configured `request_timeout` wraps the
  app in `Shaolin::Server::Timeout` (cooperative `with_timeout`; on expiry frees the fiber + its DB
  connection and returns `503`).
- `Puma#start(rack_app, config)` adds a TCP listener and `run.join`; `Puma#stop(timeout: 10)` calls
  `server.stop(true)`. (Puma has no built-in per-request timeout here — use `Rack::Timeout` /
  Puma's own.)

```ruby
Shaolin::Server::Adapters.build(:falcon)   # => #<Falcon>
Shaolin::Server::Adapters.build(:puma)      # => #<Puma>
```

### Worker / scheduler

Both install their own `TERM`/`INT` traps:

- `Worker#run` traps set the stop flag; the pool finishes the current drain, then
  `wait_for_termination` lets in-flight reactors complete. An unfinished job left mid-process is
  rolled back to `pending` (its row lock releases on the aborted transaction) and re-claimed.
- `Scheduler#run` traps call `stop!`, which sets the shutdown event so `run` unparks and shuts the
  TimerTask down.

Match the orchestrator's grace period to the work: set the Cloud Run / k8s `terminationGracePeriod`
≥ `SHAOLIN_GRACEFUL_TIMEOUT` (web) and ≥ a worker's longest reactor for clean drains.

---

## 7. ENV reference (deploy-relevant)

| ENV | Default | Used by | Notes |
| --- | --- | --- | --- |
| `SHAOLIN_ENV` | `development` | boot.rb, `Log` | `production` ⇒ `auto_schema: false`, no boot-time migrate, JSON stdout logs, swagger off. |
| `PORT` | `8080` | `Server::Config` | Container listens here; matches Dockerfile/`service.yaml`. |
| `HOST` | `0.0.0.0` | `Server::Config` | |
| `SHAOLIN_SERVER` | `falcon` | `Server::Config` | `falcon` or `puma`. |
| `SHAOLIN_GRACEFUL_TIMEOUT` | `10` | `Server` traps | Seconds for `adapter.stop`. |
| `SHAOLIN_REQUEST_TIMEOUT` | _(off)_ | `Server::Config`/`Timeout` | Per-request deadline (Falcon). |
| `SHAOLIN_WEB_CONCURRENCY` | `unbounded` | `Server.banner` | Reported only (banner). |
| `DB_NAME` | `<app>_development` | boot.rb | |
| `DB_USER` | `postgres` | boot.rb | |
| `DB_HOST` | `localhost` | boot.rb / `service.yaml` | In Cloud Run: `/cloudsql/PROJECT:REGION:INSTANCE`. |
| `DB_PORT` | `5432` | boot.rb | |
| `DB_POOL` | `5` | `AR::Connection` | **Must be ≥ concurrent fibers/threads** (web `containerConcurrency`, `WORKER_CONCURRENCY`). |
| `DB_CHECKOUT_TIMEOUT` | `5` | `AR::Connection` | Seconds to wait for a free connection. |
| `DB_REAPING_FREQUENCY` | `60` | `AR::Connection` | Reclaim leaked/dropped connections. |
| `WORKER_CONCURRENCY` | `1` | `shaolin worker` | Worker thread count; warns if `> DB_POOL`. |
| `WORKER_BATCH` | `20` | `shaolin worker` | Jobs per drain. |
| `WORKER_TX_PER_JOB` | _(off)_ | `shaolin worker` | `1`/`true` ⇒ tx-per-job (IO-bound reactors). |
| `SHAOLIN_LOG` | _(on)_ | `Log` | `off` silences all logging (tests). |
| `SHAOLIN_LOG_LEVEL` | `info` | `Log` | `debug`/`info`/`warn`/`error`. |
| `SHAOLIN_LOG_EVERYTHING` | _(off)_ | `Log` | `1`/`true` ⇒ log every command/query/event (verbose). |
| `SHAOLIN_SKIP_BOOT` | _(unset)_ | boot.rb | Load the framework without booting the app. |

---

## 8. End-to-end deploy recipe (Cloud Run)

```bash
# 1. Build + push (CI fills IMAGE_URL into deploy/service.yaml)
docker build -t region-docker.pkg.dev/PROJECT/myapp:$GIT_SHA .
docker push  region-docker.pkg.dev/PROJECT/myapp:$GIT_SHA

# 2. Release step — apply schema BEFORE shifting traffic (idempotent)
SHAOLIN_ENV=production DB_HOST=/cloudsql/PROJECT:REGION:INSTANCE \
  bundle exec shaolin migrate

# 3. Web (HTTP) — the Knative Service
kubectl apply -f deploy/service.yaml          # or: gcloud run services replace deploy/service.yaml

# 4. Worker + scheduler — same image, command overridden, minScale 1
#    web:       (default entrypoint)            bundle exec ruby bin/server
#    worker:    args: ["bundle","exec","shaolin","worker"]      # SHAOLIN_ENV=production, DB_POOL>=WORKER_CONCURRENCY
#    scheduler: args: ["bundle","exec","shaolin","scheduler"]   # any replica count — leader-elected
```

Each process boots `config/boot.rb` (so `SHAOLIN_ENV=production` ⇒ no migrate-on-boot), reads its
DB + tuning from ENV, logs JSON to stdout, and shuts down gracefully on SIGTERM.

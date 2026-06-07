# Core: kernel, providers, lifecycle, utilities

`shaolin-core` is the dependency-free foundation every other gem builds on. It provides the
shared **kernel** container, the **provider** lifecycle, the **app/boot** composition root, and a
set of small infrastructure utilities (config, context, tenant, logging, health, ids, key/value
store + cache ports, circuit breaker, inflection, imports, errors).

```ruby
require "shaolin/core"   # loads everything documented here
```

Load order (from `lib/shaolin/core.rb`): version, errors, circuit_breaker, inflector, kernel,
config, cache, store, health, tenant, context, id, keys, imports, topic, log, registry, dsl,
container_builder, injector, provider, app.

---

## Boot & wiring overview

| Piece | Role |
|-------|------|
| `Shaolin::App` | composition root — discovers modules, builds containers, starts providers, wires imports |
| `Shaolin::Lifecycle` | the phased boot engine `App` delegates to |
| `Shaolin::Provider` / `Shaolin.register_provider` | infra wiring units, started in dependency order |
| `Shaolin::Kernel` | the shared infra container (`cqrs.*`, `http.app`, …) |
| `Shaolin::Config` | typed, ENV-sourced settings |

---

## `Shaolin::Kernel`

The shared kernel container for framework-wide infrastructure (e.g. `cqrs.command_bus`,
`cqrs.event_store`) registered by providers at boot. Module containers fall back to it, so any
module resolves infra via `Deps[...]` without a cross-module dependency. It never holds module
exports, so isolation is preserved. Keys are coerced to strings.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.register` | `register(key, value = UNSET, &block)` | Register an eager `value` or a **lazy** block (called on every resolve). Returns `self`. |
| `.[]` | `[](key)` | Resolve a key; returns `nil` if unregistered. |
| `.key?` | `key?(key)` | True if the key is registered. |
| `.reset!` | `reset!` | Clear the whole container (tests). |

Gotcha: a block resolver is **re-invoked on every `[]`** (it is not memoized by the kernel
itself). For a memoized value, register an eager `value`, or memoize inside the block.

```ruby
Shaolin::Kernel.register("cqrs.command_bus", bus)        # eager
Shaolin::Kernel.register("clock") { Time.now }           # lazy, recomputed each resolve
Shaolin::Kernel["cqrs.command_bus"]                       # => bus
Shaolin::Kernel.key?("cqrs.command_bus")                  # => true
Shaolin::Kernel[:missing]                                 # => nil
```

---

## `Shaolin::Provider` & `Shaolin.register_provider`

Lifecycle providers. Other gems (activerecord, cqrs, http, jobs, redis, rabbitmq, server, …) plug
into the kernel **only** through `Shaolin.register_provider`, declaring an optional `after:`
dependency list. Start runs in dependency order; stop runs in reverse.

```ruby
def Shaolin.register_provider(name, after: [], &block)
```

Inside the block you call the `DSL`:

| DSL method | Signature | Purpose |
|------------|-----------|---------|
| `start` | `start(&blk)` | Block run on boot (wire the kernel). |
| `stop` | `stop(&blk)` | Block run on shutdown (reverse order). |

Class methods on `Shaolin::Provider`:

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.register` | `register(name, after: [], &block)` | Define a provider; `after:` is a Symbol/Array of provider names. |
| `.ordered` | `ordered` | Topologically sorted `Definition`s (dependencies first). |
| `.start_all` | `start_all` | Run every `start` block in dependency order. |
| `.stop_all` | `stop_all` | Run every `stop` block in **reverse** order. |
| `.reset!` | `reset!` | Drop all providers (tests). |

`Definition = Struct.new(:name, :after, :start_block, :stop_block, keyword_init: true)`.

Errors (both `Shaolin::BootError`):
- `"unknown provider dependency '<dep>'"` — an `after:` names a provider that was never registered.
- `"provider dependency cycle at '<name>'"` — circular `after:` chain.

```ruby
order = []
Shaolin.register_provider(:cqrs, after: [:active_record]) { start { order << :cqrs } }
Shaolin.register_provider(:active_record)                  { start { order << :active_record } }
Shaolin::Provider.start_all   # order == [:active_record, :cqrs]
Shaolin::Provider.stop_all    # reverse
```

---

## `Shaolin::Lifecycle`

Orchestrates the boot phases. Usually driven by `App`, not used directly.

```ruby
Shaolin::Lifecycle.new(root:, config:)   # root: project dir, config: a Shaolin::Config
```

| Method | Purpose |
|--------|---------|
| `#boot!` | Runs all phases, returns `self`. |
| `#shutdown!` | `Provider.stop_all`. |
| `#containers` | Hash `module_name => Shaolin::ModuleContainer`. |

Boot phases (in order):
1. **discover** — `require` every `<modules_path>/*/module.rb` (sorted).
2. **register_containers** — build a `ModuleContainer` per `Registry` definition.
3. **expose_containers** — `Kernel.register("kernel.containers") { containers }` so providers (e.g.
   `:http`) can enumerate module components **before** they start.
4. **`Provider.start_all`** — start providers in dependency order.
5. **wire** — resolve each module's `imports` against the owning module's `exports`, and validate
   declared `exports` exist.

Wiring errors:
- `ManifestError` — `imports unknown module '<name>'`, or `exports '<key>' which is not a registered component`.
- `IsolationError` — an import targets a key the owner does not export.

---

## `Shaolin.module` & `Shaolin::ModuleDefinition`

`Shaolin.module(name) { … }` is the manifest entrypoint written in each module's `module.rb`. It
builds a `ModuleDefinition`, evaluates the block against it, registers it in the `Registry`, and
returns it.

```ruby
def Shaolin.module(name, &block)
```

```ruby
# app/modules/billing/module.rb
Shaolin.module("billing") do
  imports "users.user_service", events: ["users.user_registered"]
  exports "invoice_service"
  commands_handled "create_invoice"
  events_published "invoice_issued"
end
```

`Shaolin::ModuleDefinition` is the manifest value object. Each accessor doubles as a DSL writer:
called with arguments inside the block it **appends** and returns `self`; called with no arguments
(after the block) it **reads** the accumulated list. All names are stringified.

```ruby
Shaolin::ModuleDefinition.new(name)
```

| Method | Signature | Purpose |
|--------|-----------|---------|
| `#name` | `name` | The module name (stringified). |
| `#imports` | `imports(*keys, events: [])` | Append imported component keys and subscribed `events:`; with no args, returns the imported-keys Array. |
| `#exports` | `exports(*keys)` | Append exported keys; with no args, returns the exports Array. |
| `#commands_handled` | `commands_handled(*names)` | Append command names this module handles; with no args, returns them. |
| `#events_published` | `events_published(*names)` | Append event names this module publishes; with no args, returns them. |
| `#subscribed_events` | `subscribed_events` | The event topics declared via `imports events:`. |

---

## `Shaolin::Registry`

Process-wide registry of module manifests, populated as `module.rb` files are loaded during the
discover phase.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.register` | `register(defn)` | Register a `ModuleDefinition`. Raises `ManifestError` (`"module already registered"`) on a duplicate name. |
| `.find` | `find(name)` | The `ModuleDefinition` for `name` (stringified), or `nil`. |
| `.names` | `names` | Array of registered module names. |
| `.all` | `all` | Array of all `ModuleDefinition`s. |
| `.reset!` | `reset!` | Drop all manifests (tests). |

```ruby
Shaolin::Registry.find("billing").exports   # => ["invoice_service"]
Shaolin::Registry.names                       # => ["billing", "users"]
```

---

## `Shaolin::ContainerBuilder`

Builds an isolated `Dry::System::Container` rooted at a single module's folder. Components
auto-register by file/dir convention: `user_service.rb` → key `"user_service"`
(const `<Module>::UserService`); `queries/find_user.rb` → key `"queries.find_user"`
(const `<Module>::Queries::FindUser`). Zeitwerk autoloads by constant, so module code needs no
`require_relative`.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.build` | `build(name:, dir:)` | Build and `finalize!` a zeitwerk-backed container for the module named `name` rooted at `dir`. |
| `.inflector` | `inflector` | The shared `Shaolin::Inflector.instance` (single source of truth). |

```ruby
container = Shaolin::ContainerBuilder.build(name: "billing", dir: "app/modules/billing")
container["invoice_service"]
```

---

## `Shaolin::ModuleContainer`

A facade over a module's dry-system container that enforces the **isolation contract**: a module
may resolve its own components and the keys it explicitly imported (plus shared `Kernel` infra),
and nothing else. The lifecycle's `wire` phase registers imports as resolvers that delegate to the
owning module. This is the object `App[name]` and `Lifecycle#containers[name]` return.

```ruby
Shaolin::ModuleContainer.new(definition:, container:)
```

| Method | Signature | Purpose |
|--------|-----------|---------|
| `#definition` | `definition` | The module's `ModuleDefinition` (attr_reader). |
| `#register_import` | `register_import(key, &resolver)` | Register an imported `key` whose resolver delegates to the owning module (used by `wire`). |
| `#[]` | `[](key)` | Resolve a local component, a registered import, or `Kernel` infra (in that order). Raises `IsolationError` for an undeclared key. |
| `#key?` | `key?(key)` | True if `key` resolves as a local component, an import, or `Kernel` infra. |
| `#exports?` | `exports?(key)` | True if `key` is in the manifest's declared `exports`. |
| `#keys` | `keys` | Local component keys only (excludes imports and kernel infra) — used by transports to enumerate e.g. controllers. |

```ruby
billing = App["billing"]
billing["invoice_service"]            # local component
billing["users.user_service"]         # declared import → resolves via users' container
billing["secrets.vault"]              # raises Shaolin::IsolationError (not imported)
```

---

## `Shaolin::Injector`

Produces a `dry-auto_inject` mixin bound to a module's container. Each module gets its own
`Deps = Shaolin::Injector.for(container)`, so a class can `include Deps["user_repository"]` and
receive it via keyword injection (overridable in tests).

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.for` | `for(container)` | Returns a `Dry::AutoInject(container)` mixin for the given container. |

```ruby
Deps = Shaolin::Injector.for(billing_container)

class InvoiceService
  include Deps["invoice_repository"]
  # #invoice_repository now injected; override in tests via the keyword arg
end
```

---

## `Shaolin::Topic`

Maps a dotted contract **topic** (as written in `events_published` and `imports events: [...]`) to
its event class name, using the same plain `Dry::Inflector` the generator uses. This lets a
reactor subscribe to another module's event by STRING (lint-clean, no cross-module constant
reference); the `:jobs` provider resolves the class at wire time.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.event_class_name` | `event_class_name(topic)` | `"module.event_name"` → `"Module::Events::EventName"`. Raises `ArgumentError` unless the topic is `"module.event_name"` shaped. |
| `.module_name` | `module_name(topic)` | The owning module name (the segment before the first dot) — used for graph edges. |

```ruby
Shaolin::Topic.event_class_name("conversions.conversion_recorded")
# => "Conversions::Events::ConversionRecorded"
Shaolin::Topic.module_name("conversions.conversion_recorded")
# => "conversions"
```

---

## `Shaolin::App`

The composition root. Boots an application from a project root and exposes each module's
isolation-enforcing container.

```ruby
Shaolin::App.new(root:, env: ENV)
```

| Method | Signature | Purpose |
|--------|-----------|---------|
| `#initialize` | `initialize(root:, env: ENV)` | Builds a `Config` from `env` and a `Lifecycle` rooted at `root`. |
| `#boot!` | `boot!` | Discover modules, build containers, start providers, wire imports. Returns `self`. |
| `#shutdown!` | `shutdown!` | Stop providers in reverse order. |
| `#modules` | `modules` | Array of module names. |
| `#[]` | `[](name)` | Fetch a module's container (`KeyError` if absent). |

```ruby
# config/boot.rb
require "shaolin"
# ...register providers...
App = Shaolin::App.new(root: __dir__ + "/..").boot!
App.modules                       # => ["users", "billing"]
App["users"]["user_service"]      # resolve a module component
```

---

## `Shaolin::Config`

Typed, ENV-sourced application configuration. Per-instance (via `Dry::Configurable`) so multiple
apps/tests don't share state. Reads ENV **at construction time**.

```ruby
Shaolin::Config.new(env: ENV)
```

| Setting | Method | ENV var | Default |
|---------|--------|---------|---------|
| `modules_path` | `#modules_path` | `SHAOLIN_MODULES_PATH` | `"app/modules"` |
| `env` | `#env` | `SHAOLIN_ENV` | `"development"` |

```ruby
cfg = Shaolin::Config.new(env: { "SHAOLIN_ENV" => "production" })
cfg.env           # => "production"
cfg.modules_path  # => "app/modules"
```

---

## `Shaolin::Context`

The blessed channel for **request-scoped** values flowing from middleware to controllers (and into
logs) — a generic fiber/thread-local key-value bag (whereas `Tenant` carries just the tenant). The
HTTP layer clears it at the end of each request so values never leak across requests on a reused
fiber/thread. Its contents are merged into every `Shaolin::Log` record. `KEY = :shaolin_context`.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.store` | `store` | The underlying hash (`Thread.current[KEY] ||= {}`). |
| `.[]` | `[](key)` | Read a field. |
| `.[]=` | `[]=(key, value)` | Write a field. |
| `.to_h` | `to_h` | A **dup** of the bag. |
| `.clear` | `clear` | Reset to `{}`. |
| `.with` | `with(**fields)` | Merge `fields` for the block, restore previous after (block form). |

```ruby
Shaolin::Context[:project_id] = "p_42"          # in middleware
Shaolin::Context.with(request_id: "req-1") do
  Shaolin::Log.info("served")                    # record carries project_id + request_id
end
Shaolin::Context.clear                            # end of request
```

---

## `Shaolin::Tenant`

Multi-tenancy context: a request/job-scoped "current tenant" held per fiber/thread. shaolin only
**carries** the value — isolation is enforced by YOUR code (stream prefixes, ids, read-model
filters). Auto-attached to every log record. `KEY = :shaolin_current_tenant`. (`Thread.current` is
fiber-local under Falcon, so it is correct for both server models.)

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.current` | `current` | Current tenant id (or `nil`). |
| `.current=` | `current=(id)` | Set it. |
| `.with` | `with(id)` | Set for the block, restore previous after. |

```ruby
Shaolin::Tenant.with("acme") do
  Shaolin::Tenant.current     # => "acme"
  Shaolin::Log.info("scoped") # record[:tenant] == "acme"
end
```

---

## `Shaolin::Log`

The unified structured logger. Everything (HTTP, worker, scheduler, commands, events, LLM harness)
logs structured records to pluggable **sinks** — JSON to stdout in production, human-readable in
dev. Each record auto-merges the current tenant, the request-scoped `Context`, and the log
`context`. `LEVELS = %i[debug info warn error]`.

### Emitting

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.debug` | `debug(msg, **f)` | Emit at `:debug`. |
| `.info` | `info(msg, **f)` | Emit at `:info`. |
| `.warn` | `warn(msg, **f)` | Emit at `:warn`. |
| `.error` | `error(msg, **f)` | Emit at `:error`. |
| `.emit` | `emit(level, msg, **fields)` | Low-level emit (the four above delegate here). |

Each record is `{ ts:, level:, msg:, <tenant>, <context fields>, <log context fields>, <fields> }`.
`ts` is `Time.now.utc.iso8601(3)`. `msg` and `level` are stringified. Merge precedence (last
wins): tenant → `Context.to_h` → log `context` → call `fields`.

### Config / context

| Method | Signature | Purpose / Default |
|--------|-----------|-------------------|
| `.level` | `level` | Current threshold; defaults to `ENV["SHAOLIN_LOG_LEVEL"]` or `:info`. |
| `.level=` | `level=(lvl)` | Set threshold (Symbol). |
| `.sinks` | `sinks` | Array of sinks; defaults to one default sink (see below). |
| `.sinks=` | `sinks=(list)` | Replace sinks (wraps in `Array()`). |
| `.add_sink` | `add_sink(sink)` | Append a sink. |
| `.everything?` | `everything?` | True when `SHAOLIN_LOG_EVERYTHING` is `"1"` or `"true"` — the firehose. |
| `.context` | `context` | Fiber/thread-local fields hash. |
| `.with` | `with(**fields)` | Merge `fields` into context for the block, restore after. |
| `.reset!` | `reset!` | Clear sinks, level, and context (tests). |

A **sink** is anything responding to `call(record)`. The default sink is `Sinks::Stdout` when
`SHAOLIN_ENV == "production"`, else `Sinks::Pretty`.

### ENV vars / gotchas

| ENV | Effect |
|-----|--------|
| `SHAOLIN_LOG=off` | Silences all emission (tests). |
| `SHAOLIN_LOG_LEVEL` | Initial level (e.g. `warn`); read once, memoized. |
| `SHAOLIN_LOG_EVERYTHING=1\|true` | Buses + event store log every command/query/event (verbose). |
| `SHAOLIN_ENV=production` | Selects the JSON `Stdout` default sink. |

Gotcha: records **below** the configured level are dropped before sinks run. `level`/`sinks` are
memoized — call `reset!` between tests.

### Sinks

| Sink | Constructor | Behavior |
|------|-------------|----------|
| `Sinks::Stdout` | `new(io = $stdout)` | One JSON object per line (`#call` writes `JSON.generate(record)`). |
| `Sinks::Pretty` | `new(io = $stdout)` | Compact human line: `ts LEVEL msg k=v …`. `FIXED = %i[ts level msg]`. |
| `Sinks::Batch` | `new(flush_size: 100, flush_interval: 5, &flusher)` | Thread-safe buffering for DB/remote targets. |

`Sinks::Batch` methods: `#call(record)` appends and flushes via the `flusher` block when the buffer
reaches `flush_size`; `#flush` flushes the remainder immediately; `#start!` spawns a background
thread that flushes every `flush_interval` seconds (idempotent — only one thread). The `flusher`
receives an Array of records. For GCP the recommended path is JSON-to-stdout → Cloud Logging → a
Log Router sink to BigQuery (zero app code); use `Batch` for other targets.

```ruby
Shaolin::Log.level = :debug
Shaolin::Log.sinks = [->(rec) { captured << rec }]   # test sink
Shaolin::Log.with(request_id: "req-1") { Shaolin::Log.info("served", status: 200) }

batch = Shaolin::Log::Sinks::Batch.new(flush_size: 2) { |records| ship(records) }
batch.call({ msg: "a" }); batch.call({ msg: "b" })   # flushes [a, b]
batch.flush
```

---

## `Shaolin::Health`

Readiness registry. Providers contribute named checks (`:active_record` → DB ping, `:redis` →
PING); the HTTP layer exposes them at `/readyz`. Liveness (`/healthz`) stays a static 200.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.register` | `register(name, &check)` | Add a check; `name` is stringified, block returns truthy when reachable. |
| `.checks` | `checks` | The registered checks hash. |
| `.status` | `status` | `[overall_ok, { "name" => true/false, … }]`. A check that **raises** counts as not-ready (never escapes the probe). |
| `.reset!` | `reset!` | Clear all checks (tests). |

```ruby
Shaolin::Health.register(:database) { ActiveRecord::Base.connection.active? }
Shaolin::Health.register(:redis)    { redis.ping == "PONG" }
ok, results = Shaolin::Health.status
# => [false, { "database" => true, "redis" => false }]
```

---

## `Shaolin::Id`

UUID helpers for event sourcing. `DEFAULT_NAMESPACE = "shaolin"`.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.generate` | `generate` | Random v4 UUID (`SecureRandom.uuid`) for genuinely new entities. |
| `.deterministic` | `deterministic(*parts, namespace: DEFAULT_NAMESPACE)` | Stable v5-style UUID (SHA1 over `namespace` + joined `parts`). |

`deterministic` is the canonical idempotent-ingest key: identical inputs always yield the same id,
so a re-delivered message maps to the same aggregate. It is a hand-rolled v5 UUID (version nibble
`5`, RFC 4122 variant), stable across processes and Ruby versions. Raises `ArgumentError` if
`parts` is empty. Different `namespace:` ⇒ different id.

```ruby
Shaolin::Id.generate                                  # => "f47ac10b-58cc-4372-a567-0e02b2c3d479"
Shaolin::Id.deterministic("orders", "ext-123")        # stable across runs
Shaolin::Id.deterministic("orders", "ext-123") ==
  Shaolin::Id.deterministic("orders", "ext-123")      # => true
Shaolin::Id.deterministic("x", namespace: "tenant-a") # namespaced
```

---

## `Shaolin::Keys`

Key normalization for the symbol/string boundary. Event data round-trips with symbol keys and
params are symbolized, so inside shaolin you rely on symbol keys; the mismatch shows up at the
jsonb edge (an ActiveRecord jsonb column reads back with **string** keys).

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.deep_symbolize` | `deep_symbolize(obj)` | Recursively symbolize hash keys through nested Hashes/Arrays. Non-collections pass through; keys that can't `to_sym` are left as-is. |

```ruby
Shaolin::Keys.deep_symbolize("user" => { "roles" => ["admin"] })
# => { user: { roles: ["admin"] } }
```

---

## `Shaolin::Store` (+ `Store::Memory`)

The key-value/hash store **port** — "X as a database" (read models, sessions, counters, LLM state).
Domain code depends on this interface; `Shaolin::Redis::Store` binds it to Redis, `Store::Memory`
is the in-process implementation for tests. Both JSON-round-trip values, so reads come back with
**symbol keys**. Bare module methods all `raise NotImplementedError`.

Port interface:

| Method | Signature | Purpose |
|--------|-----------|---------|
| `set` | `set(key, value, ttl: nil)` | Store a JSON value; returns the value. |
| `get` | `get(key)` | Read (symbol-keyed) or `nil`. |
| `delete` | `delete(key)` | Returns `1` if deleted, else `0`. |
| `exists?` | `exists?(key)` | Present in kv **or** hashes. |
| `increment` | `increment(key, by: 1, ttl: nil)` | Atomic counter; `ttl:` sets expiry on first create (rate limits). |
| `decrement` | `decrement(key, by: 1)` | Atomic decrement. |
| `hset` | `hset(key, field, value)` | Set a hash field (JSON value); returns `1`. |
| `hget` | `hget(key, field)` | Read a hash field (symbol-keyed) or `nil`. |
| `hgetall` | `hgetall(key)` | All fields as a symbol-keyed hash. |
| `keys` | `keys(pattern = "*")` | Glob match over kv + hash keys. |

`Store::Memory` (process-local, mirrors Redis semantics; **not** shared across processes):
`new` takes no args. Keys are stringified internally. `increment`'s `ttl:` is a no-op in-memory.
`keys` translates the glob `*` to a regex.

```ruby
store = Shaolin::Store::Memory.new
store.set("user:1", { id: "1", name: "Neo" })
store.get("user:1")                 # => { id: "1", name: "Neo" }
store.increment("hits", by: 4)      # => 4
store.hset("session:a", "user_id", "u1")
store.hgetall("session:a")          # => { user_id: "u1" }
store.keys("user:*")                # => ["user:1"]
```

---

## `Shaolin::Cache` (+ `Cache::Memory`)

The cache **port**. Domain code and read models depend only on this interface; a concrete adapter
(e.g. `Shaolin::Redis::Cache`) binds it to a backend. `now:` is injectable so TTL is testable.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `read` | `read(key, now: Time.now)` | Abstract — raises `NotImplementedError`. |
| `write` | `write(key, value, ttl: nil)` | Abstract — store with optional TTL (seconds). |
| `delete` | `delete(key)` | Abstract. |
| `clear` | `clear` | Abstract — drop everything. |
| `exist?` | `exist?(key, now: Time.now)` | **Concrete** — `!read(...).nil?`. |
| `fetch` | `fetch(key, ttl: nil, now: Time.now) { … }` | **Concrete** cache-aside: return cached, else compute via block, write (with `ttl`), and return. |

`Cache::Memory` (process-local, lazy TTL expiry on read; **not** shared across processes): `new`
takes no args. Uses `Entry = Struct.new(:value, :expires_at)`; `expires_at` is computed from
`Time.now + ttl` at write time. Gotcha: `read`/`exist?` accept an injectable `now:`, but `write`
always uses `Time.now` for the expiry baseline.

```ruby
cache = Shaolin::Cache::Memory.new
cache.fetch("report:42", ttl: 60) { expensive_compute }   # miss → computes + stores
cache.fetch("report:42") { never_called }                 # hit → cached value
cache.write("k", "v", ttl: 60)
cache.read("k", now: Time.now + 61)                        # => nil (expired)
cache.exist?("k")                                          # => false
```

---

## `Shaolin::CircuitBreaker`

A small thread-safe circuit breaker for outbound calls (RabbitMQ/Redis/HTTP). After `threshold`
consecutive failures it OPENs and fast-fails for `reset_timeout` seconds, then HALF-OPENs to trial
one call through — success closes it, a failure re-opens it.

```ruby
CircuitBreaker.new(threshold: 5, reset_timeout: 30,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
```

| Param | Default | Meaning |
|-------|---------|---------|
| `threshold:` | `5` | Consecutive failures before opening. |
| `reset_timeout:` | `30` | Seconds open before half-open. |
| `clock:` | monotonic lambda | Injectable clock (tests). |

| Method | Signature | Purpose |
|--------|-----------|---------|
| `#call` | `call { … }` | Run the block when allowed; raises `OpenError` (without calling) while open. Re-raises the block's exception after recording a failure. Returns the block result. |
| `#state` | `state` | `:closed` \| `:open` \| `:half_open` (computed; promotes open→half_open once the cooldown elapsed). |

`OpenError < Shaolin::Error` is raised in place of the block while open. A **success** while closed
resets the failure count to 0.

```ruby
breaker = Shaolin::CircuitBreaker.new(threshold: 3, reset_timeout: 30)
breaker.call { publisher.publish(msg) }   # normal
# after 3 consecutive failures:
breaker.state                              # => :open
breaker.call { … }                         # raises Shaolin::CircuitBreaker::OpenError, block not run
```

---

## `Shaolin::Inflector`

THE inflector for shaolin — one shared instance so the generator's names, the zeitwerk autoloader,
and module namespaces all agree on acronyms. `ACRONYMS = %w[DTO ID API HTTP URL UUID UI]`.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `.instance` | `instance` | The memoized `Dry::Inflector` with shaolin's acronyms. |
| `.camelize` | `camelize(string)` | e.g. `"url_maps"` → `"URLMaps"`. |
| `.underscore` | `underscore(string)` | e.g. `"URLMaps"` → `"url_maps"`. |
| `.singularize` | `singularize(string)` | e.g. `"orders"` → `"order"`. |
| `.pluralize` | `pluralize(string)` | e.g. `"order"` → `"orders"`. |

```ruby
Shaolin::Inflector.camelize("http_api")   # => "HTTPAPI"
Shaolin::Inflector.underscore("UUIDStore") # => "uuid_store"
```

---

## `Shaolin::Imports` (mixin)

Typed-ish cross-module access for components (controllers, handlers). Instead of hand-navigating
`Kernel["kernel.containers"][...]`, `include Shaolin::Imports` and call `import("other.thing")`. It
resolves via the component's OWN module container (isolation still holds) and validates the key
against the module manifest's declared `imports` + `imports events:`, raising otherwise. `shaolin
lint` also checks these calls statically.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `#import` | `import(key)` | Resolve a declared import for the including class's module. |

The owning module is derived from `self.class.name`'s first namespace segment (e.g.
`Users::SomeController` → module `"users"`). If `key` is not in `definition.imports +
definition.subscribed_events`, it raises `Shaolin::Error` with a message telling you to declare it
in `module.rb`.

```ruby
module Billing
  class InvoiceController
    include Shaolin::Imports
    def call
      user_service = import("users.user_service")   # must be declared in billing/module.rb
      # ...
    end
  end
end
```

---

## Error classes

All inherit `Shaolin::Error < StandardError`, which exposes a machine-readable contract for
agent/LLM tooling.

| Class | Constructor | Raised when |
|-------|-------------|-------------|
| `Error` | `Error.new(message)` | Base. `#to_contract` ⇒ `{ code: <ClassName>, message: <message> }`. |
| `ManifestError` | `new(msg, module_name: nil)` | Manifest structurally invalid (bad export, cycle, dup name, unknown import target). Prefixes `[module_name]`; exposes `#module_name`. |
| `IsolationError` | `new(consumer:, key:, owner:)` | A module accesses a key it didn't import / the owner doesn't export. |
| `BootError` | `BootError.new(message)` | Boot/provider failures (cycles, unknown providers). |
| `CircuitBreaker::OpenError` | — | Circuit open; raised in place of the wrapped call. |

```ruby
begin
  app.boot!
rescue Shaolin::Error => e
  e.to_contract   # => { code: "IsolationError", message: "module 'billing' may not access ..." }
end
```

# Modules & isolation

A **module is a folder** under `app/modules/<name>/` — a bounded context with one explicit
public contract, the `module.rb` **manifest**. Modules may only reach each other through
declared `imports` / `exports` / events; everything else is internal. Isolation is **enforced
statically** by `shaolin lint` (pure Prism AST analysis, no boot) and **at runtime** by
`import("...")`, which validates the key against the manifest before resolving it.

---

## 1. Module folder anatomy

Generate a module with `shaolin g module NAME`. The default is a **CRUD** module; pass `--es`
for an **event-sourced** module, and `--reactor` (requires `--es`) to also scaffold an async
reactor.

```bash
shaolin g module users          # CRUD (default)
shaolin g module orders --es    # event-sourced CQRS
shaolin g module orders --es --reactor   # + async reactor
```

| Flag        | Type    | Default | Meaning                                              |
| ----------- | ------- | ------- | ---------------------------------------------------- |
| `--es`      | boolean | `false` | Event-sourced CQRS module (default is CRUD)          |
| `--crud`    | boolean | `false` | Plain CRUD module (the default — explicit opt-in)    |
| `--reactor` | boolean | `false` | Also scaffold an async reactor (**requires `--es`**) |

`g` is aliased to `generate`. The generator writes into `Dir.pwd` (the app root).

**CRUD module** (`templates/crud/`) — an AR-backed bounded context, no event store:

```
app/modules/users/
  module.rb        # manifest (initially empty body)
  controller.rb    # < Shaolin::HTTP::Controller
  model.rb         # ActiveRecord model
  dto.rb           # request/response DTO
  migration.rb     # create table
  CONTRACT.md      # human/agent-readable contract
```

**Event-sourced module** (`templates/module/`) — full CQRS/ES split:

```
app/modules/orders/
  module.rb            # manifest (commands_handled + events_published)
  aggregate.rb         # event-sourced aggregate
  command.rb           # command struct
  command_handler.rb   # < Shaolin::CQRS::CommandHandler  (includes Shaolin::Imports)
  event.rb             # domain event under Orders::Events
  projection.rb        # synchronous projector -> read model
  read_model.rb        # AR read model (the query side)
  query.rb             # query struct
  query_handler.rb     # < Shaolin::CQRS::QueryHandler     (includes Shaolin::Imports)
  controller.rb        # < Shaolin::HTTP::Controller        (includes Shaolin::Imports)
  reactor.rb           # < Shaolin::Jobs::Reactor  (only with --reactor)
  migration.rb
  CONTRACT.md
```

Components that subclass `Shaolin::CQRS::CommandHandler`, `Shaolin::CQRS::QueryHandler`, or
`Shaolin::HTTP::Controller` already `include Shaolin::Imports`, so `import("...")` is available
in handlers and controllers without any extra mixin.

---

## 2. The `module.rb` manifest

The manifest is loaded during the discover phase. It is a plain Ruby file calling
`Shaolin.module`.

### `Shaolin.module(name, &block) → ModuleDefinition`

Builds a `ModuleDefinition`, evaluates the block against it, registers it in the `Registry`,
and returns it. `name` is coerced to a string.

```ruby
# app/modules/users/module.rb
Shaolin.module "users" do
  imports "notifications.mailer"          # declared cross-module dependencies
  imports events: ["billing.invoice_paid"]# event topics this module subscribes to
  exports "user_service", "queries.find_user"
  commands_handled "Users::Commands::RegisterUser"
  events_published "users.user_registered"
end
```

A freshly generated **CRUD** manifest has an empty body; an **ES** manifest is pre-filled:

```ruby
Shaolin.module "orders" do
  commands_handled "Orders::Commands::CreateOrder"
  events_published "orders.order_created"
end
```

### `class Shaolin::ModuleDefinition`

The manifest value object. **Each accessor doubles as a DSL writer**: called with arguments
inside the block it *appends*; called with no arguments (after the block) it *reads*. Writers
return `self` so they chain. All keys/names are coerced to strings, and `*splat` args are
flattened.

| Method                                            | As writer (args given)                            | As reader (no args) → returns |
| ------------------------------------------------- | ------------------------------------------------- | ----------------------------- |
| `initialize(name)`                                | —                                                 | new definition (name → `String`) |
| `name` *(attr_reader)*                            | —                                                 | the module name (`String`)    |
| `imports(*keys, events: [])`                      | appends `keys` to imports, `events` to subscriptions | `@imports` (`Array<String>`)  |
| `exports(*keys)`                                  | appends export keys                               | `@exports` (`Array<String>`)  |
| `commands_handled(*names)`                        | appends handled command names                     | `@commands_handled` (`Array<String>`) |
| `events_published(*names)`                        | appends published event topics                    | `@events_published` (`Array<String>`) |
| `subscribed_events`                               | — (reader only)                                   | `@subscribed_events` (`Array<String>`) |

```ruby
defn = Shaolin.module("users") do
  imports "notifications.mailer"
  exports "user_service", "queries.find_user"
  commands_handled "RegisterUser"
  events_published "users.user_registered"
end

defn.name             # => "users"
defn.imports          # => ["notifications.mailer"]
defn.exports          # => ["user_service", "queries.find_user"]
defn.commands_handled # => ["RegisterUser"]
defn.events_published # => ["users.user_registered"]
```

**`imports` vs `imports events:`** — both arrive through the same method. Positional `*keys`
become **container imports** (resolved by `import("...")`); the `events:` keyword becomes
**topic subscriptions** (stored separately in `subscribed_events`, *not* in `imports`):

```ruby
defn = Shaolin.module("billing_consumer") { imports events: ["billing.invoice_paid"] }
defn.subscribed_events # => ["billing.invoice_paid"]
defn.imports           # => []   (events: does NOT populate imports)
```

> **Gotcha:** `imports` returns the reader only when *both* `keys` is empty *and* `events` is
> empty. `imports(events: [...])` with no positional keys still acts as a writer.

### `module Shaolin::Registry`

Process-wide registry of manifests, populated as `module.rb` files load. Singleton-method API
(`class << self`):

| Method            | Purpose                                                         |
| ----------------- | --------------------------------------------------------------- |
| `register(defn)`  | Store `defn` by `defn.name`; **raises `ManifestError`** on a duplicate name |
| `find(name)`      | Look up a definition by name (string-coerced) → `ModuleDefinition` or `nil` |
| `names`           | All registered module names → `Array<String>`                   |
| `all`             | All registered definitions → `Array<ModuleDefinition>`          |
| `reset!`          | Clear the registry (used in specs / re-discovery) → `{}`        |

```ruby
Shaolin::Registry.reset!
defn = Shaolin.module("users") { exports "user_service" }
Shaolin::Registry.find("users") # => #<ModuleDefinition ...> (the same object)
Shaolin::Registry.names         # => ["users"]
Shaolin.module("users") {}      # raises Shaolin::ManifestError: [users] module already registered
```

---

## 3. `import("mod.key")` — validated cross-module access

### `module Shaolin::Imports`

Mixin giving components typed-ish cross-module access. Instead of hand-navigating
`Shaolin::Kernel["kernel.containers"][...][...]` (a typo only fails at runtime), call
`import("other.thing")`.

#### `import(key) → resolved value`

1. Derives the **caller's own module** from `self.class.name` — the first `::` segment,
   underscored via `Shaolin::Inflector.underscore` (e.g. `Billing::Charger` → `"billing"`).
2. Looks up that module's manifest in the `Registry`; the allow-list is
   `definition.imports + definition.subscribed_events`.
3. **Raises `Shaolin::Error`** if `key` is not declared, with a message telling you exactly
   which line to add to `module.rb`.
4. Otherwise resolves through the module's **own** container —
   `Shaolin::Kernel["kernel.containers"].fetch(mod)[key]` — so isolation still holds.

```ruby
module Billing
  class Charger
    include Shaolin::Imports
    def call = import("accounts.balance_reader")
  end
end

# module.rb must declare it:
Shaolin.module("billing") { imports "accounts.balance_reader" }

Billing::Charger.new.call          # => the resolved balance reader
# import("accounts.secret") raises:
#   Shaolin::Error: module "billing" does not import "accounts.secret" —
#   declare it in module.rb (`imports "accounts.secret"` or `imports events: ["accounts.secret"]`)
```

> **Gotcha:** the caller's module is inferred purely from the class's top-level namespace, so a
> component **must** live under its module's namespace (`Billing::...`) for resolution to work.
> Both `imports` keys *and* `imports events:` topics are accepted by `import`.

---

## 4. Topic-string event subscription

Reactors subscribe to **another** module's event by **string topic**, never by referencing the
event constant — that keeps the subscriber lint-clean (no cross-module constant reference). The
`:jobs` provider resolves the class at wire time using the same inflection the generator uses.

### `module Shaolin::Topic`

`module_function` methods; `INFLECTOR = Dry::Inflector.new` (plain, **not** the acronym-aware
`Shaolin::Inflector`).

| Method                     | Purpose                                                                 |
| -------------------------- | ----------------------------------------------------------------------- |
| `event_class_name(topic)`  | Maps `"module.event_name"` → `"Module::Events::EventName"`. **Raises `ArgumentError`** unless the topic has the `module.event` shape. |
| `module_name(topic)`       | The owning module (segment before the first dot) — used for graph edges. |

```ruby
Shaolin::Topic.event_class_name("conversions.conversion_recorded")
# => "Conversions::Events::ConversionRecorded"
Shaolin::Topic.module_name("conversions.conversion_recorded")
# => "conversions"
Shaolin::Topic.event_class_name("bad")  # raises ArgumentError: topic must be 'module.event_name', got "bad"
```

Subscribe in a reactor with the **string** form; declare the topic in your manifest under
`imports events:`:

```ruby
# app/modules/dispatches/module.rb
Shaolin.module "dispatches" do
  imports events: ["conversions.conversion_recorded"]
end

# app/modules/dispatches/reactors/conversion_dispatcher.rb
module Dispatches
  module Reactors
    class ConversionDispatcher < Shaolin::Jobs::Reactor
      on("conversions.conversion_recorded") { |event| handle(event) }  # string topic = lint-clean
    end
  end
end
```

Referencing the other module's constant instead — `on(Conversions::Events::ConversionRecorded)`
— compiles, but `shaolin lint` flags it as a `cross-module-reference`.

---

## 5. What `shaolin lint` enforces

```bash
shaolin lint              # module-internal violations are hard errors; outside-graph = warnings
shaolin lint --strict     # promote outside-graph findings to failures (also SHAOLIN_LINT_STRICT=1)
```

`lint` requires `app/modules/` in `Dir.pwd` (else `Thor::Error: no app/modules in ...`). It runs
`Shaolin::CLI::Isolation` against the modules dir — pure Prism static analysis, **no boot**.

| Option / ENV                  | Type    | Default | Effect                                                       |
| ----------------------------- | ------- | ------- | ------------------------------------------------------------ |
| `--strict`                    | boolean | `false` | Outside-graph findings count as failures (exit non-zero)     |
| `SHAOLIN_LINT_STRICT=1`       | env     | unset   | Same as `--strict` (OR'd with the flag)                      |

Exit logic: `failures = (module violations) + (strict ? outside findings : 0)`. Any failure
raises `Thor::Error: N isolation violation(s)`. Module-internal violations **always** fail;
outside-graph findings only fail under `--strict`/`SHAOLIN_LINT_STRICT=1`.

### `class Shaolin::CLI::Isolation`

```ruby
require "shaolin/cli/isolation"
iso = Shaolin::CLI::Isolation.new("app/modules")
iso.violations              # Array<Violation> — per-module, always hard errors
iso.outside_violations(".") # Array<Violation> — code outside the module graph
```

| Method                          | Purpose                                                                      |
| ------------------------------- | ---------------------------------------------------------------------------- |
| `initialize(modules_dir)`       | Scans direct child dirs of `modules_dir`; maps each to its namespace (`Naming.namespace`). |
| `violations`                    | Per-module isolation findings (cross-module refs, escaping requires, undeclared imports). |
| `outside_violations(app_root)`  | Findings in app code **outside** `modules_dir`, skipping `EXEMPT_DIRS`.       |

`Violation = Struct.new(:file, :line, :rule, :message)` with `#to_s` → `"file:line  rule: message"`.

### Rules emitted by `#violations` (per-module — always hard errors)

| `rule`                    | Triggered by                                                                                 |
| ------------------------- | -------------------------------------------------------------------------------------------- |
| `cross-module-reference`  | A root constant whose name is **another** module's namespace (e.g. `Billing::Invoice` inside `users/`). Includes referencing another module's event **class**. |
| `require-escapes-module`  | `require_relative` whose resolved path is outside the module's own folder.                   |
| `undeclared-import`       | `import("x")` (no receiver) where `"x"` is not declared in the module's `module.rb` (via `imports` or `imports events:`). |

The undeclared-import allow-list is read straight from the manifest AST (`ManifestWalker`):
every string literal positional arg to `imports`, plus every string inside an `events:` array.

```ruby
# users/notifier.rb — both rules fire:
require_relative "../billing/invoice"   # require-escapes-module
module Users
  class Notifier
    def call = Billing::Invoice.new      # cross-module-reference
  end
end
```

```ruby
# billing/charger.rb with manifest: imports "accounts.balance_reader"
def ok  = import("accounts.balance_reader")  # declared    -> clean
def bad = import("accounts.secret")          # undeclared  -> undeclared-import
```

A reactor subscribing **by topic string** (`on("conversions.conversion_recorded")`) is **not**
flagged — only constant references to another module are.

### Rules emitted by `#outside_violations` (code outside the module graph)

App code outside `app/modules/**` has zero isolation enforcement, so a "god-orchestrator" in,
say, `app/telegram/` would otherwise be silent. This scan flags two smells (warnings by default;
`--strict` promotes them to failures):

| `rule`                      | Triggered by                                                                  |
| --------------------------- | ----------------------------------------------------------------------------- |
| `kernel-internal-access`    | Reading `Shaolin::Kernel[...]` internals from outside a module.               |
| `outside-module-reference`  | Referencing a module's namespace constant from outside the module graph.      |

`EXEMPT_DIRS` (first path segment under `app_root`) are skipped, since they legitimately touch
the Kernel/bootstrap:

```
config  bin  spec  test  vendor  tmp  .bundle  .git  node_modules
```

Files under `modules_dir` are also skipped here — they are the per-module check's domain.
Repo-root entrypoints (e.g. `run_bot.rb`, not under any exempt dir) **are** scanned.

```ruby
# app/telegram/ingress.rb — both outside-graph rules fire:
class Ingress
  def call
    Shaolin::Kernel["cqrs.command_bus"].call(Billing::Invoice.new)
    # kernel-internal-access  +  outside-module-reference (Billing)
  end
end
# config/boot.rb, bin/worker.rb, spec/*_spec.rb — exempt, never flagged.
```

> **Best practice:** put orchestration *inside* a module (with a manifest), not in a loose
> `app/<thing>/` dir, so isolation is actually enforced. Run `shaolin lint --strict` in CI to
> make outside-graph reach-ins fail the build.

---

## 6. Related errors

| Class                                          | Raised when                                                              |
| ---------------------------------------------- | ------------------------------------------------------------------------ |
| `Shaolin::Error`                               | Base; `#to_contract` → `{ code:, message: }`. `import` raises this for an undeclared key. |
| `Shaolin::ManifestError(msg, module_name: nil)`| Structurally invalid manifest — duplicate registration, bad export, cycle. Has `#module_name`; message is prefixed `[name]`. |
| `Shaolin::IsolationError(consumer:, key:, owner:)` | Runtime access to a key a module did not import / the owner does not export. |

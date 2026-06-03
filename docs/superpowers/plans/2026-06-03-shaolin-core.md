# shaolin-core Implementation Plan

> **STATUS: ✅ COMPLETE (2026-06-03).** All tasks implemented TDD-first; 25 examples, 0 failures. Verified against dry-system 1.2.5 / dry-auto_inject 1.2.1 / dry-configurable 1.4.0. Merged to master.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the production `shaolin-core` gem — the kernel that discovers modules, builds a dry-system container per module, wires imports/exports, exposes a DI injector, and runs a provider-based boot lifecycle.

**Architecture:** A monorepo of gems under `gems/`. `shaolin-core` wraps dry-system: each module folder becomes a sub-container auto-registered from its files; a manifest DSL (`Shaolin.module`) declares `imports`/`exports`; the kernel validates manifests, wires cross-module imports, and boots providers in dependency order. No HTTP/AR/CQRS knowledge lives here — they plug in via `Shaolin.register_provider`.

**Tech Stack:** Ruby 4.0.5, dry-system 1.x, dry-auto_inject 1.x, dry-configurable 1.x, dry-inflector, RSpec. Reference spec: `docs/superpowers/specs/2026-06-03-shaolin-core-design.md`.

**Conventions for every task:** TDD (failing test first), small focused files (no file > ~150 lines), run `bundle exec rspec` from `gems/shaolin-core`, commit after green. Verify any dry-system API against the installed gem the moment a test fails on it — never guess; if the real API differs from a code block here, follow the gem and note it.

---

## File Structure

```
Gemfile                                   # root: paths to each gem
gems/shaolin-core/
  shaolin-core.gemspec
  lib/shaolin/core/version.rb
  lib/shaolin/core.rb                      # entrypoint: require tree + Shaolin module
  lib/shaolin/config.rb                    # dry-configurable typed config (ENV-sourced)
  lib/shaolin/module_definition.rb         # the manifest value object
  lib/shaolin/dsl.rb                        # Shaolin.module(name){…} DSL
  lib/shaolin/registry.rb                  # module registry
  lib/shaolin/container_builder.rb         # build a dry-system container per module
  lib/shaolin/injector.rb                  # Deps[...] (dry-auto_inject)
  lib/shaolin/provider.rb                  # provider registration + ordering
  lib/shaolin/lifecycle.rb                 # boot phases (discover→…→finalize→shutdown)
  lib/shaolin/app.rb                       # composition root
  lib/shaolin/errors.rb                    # ManifestError, IsolationError, BootError
  spec/spec_helper.rb
  spec/support/tmp_app.rb                  # helper to scaffold synthetic modules in a tmpdir
  spec/**/*_spec.rb
```

---

## Task 0: Monorepo + gem skeleton

**Files:**
- Create: `Gemfile`, `gems/shaolin-core/shaolin-core.gemspec`, `gems/shaolin-core/lib/shaolin/core/version.rb`, `gems/shaolin-core/lib/shaolin/core.rb`, `gems/shaolin-core/.rspec`, `gems/shaolin-core/spec/spec_helper.rb`, `gems/shaolin-core/Rakefile`

- [ ] **Step 1: Write `gems/shaolin-core/lib/shaolin/core/version.rb`**

```ruby
module Shaolin
  module Core
    VERSION = "0.1.0"
  end
end
```

- [ ] **Step 2: Write the gemspec** `gems/shaolin-core/shaolin-core.gemspec`

```ruby
require_relative "lib/shaolin/core/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-core"
  spec.version     = Shaolin::Core::VERSION
  spec.summary     = "shaolin kernel: modular DI + lifecycle over dry-system"
  spec.authors     = ["shaolin"]
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "dry-system", "~> 1.0"
  spec.add_dependency "dry-auto_inject", "~> 1.0"
  spec.add_dependency "dry-configurable", "~> 1.0"
  spec.add_dependency "dry-inflector", "~> 1.0"

  spec.add_development_dependency "rspec", "~> 3.13"
end
```

- [ ] **Step 3: Write root `Gemfile`**

```ruby
source "https://rubygems.org"
gemspec path: "gems/shaolin-core"
```

- [ ] **Step 4: Write `gems/shaolin-core/lib/shaolin/core.rb`**

```ruby
require_relative "core/version"

module Shaolin
  # entrypoint; sub-files required as they are added in later tasks
end
```

- [ ] **Step 5: Write `gems/shaolin-core/.rspec` and `spec/spec_helper.rb`**

`.rspec`:
```
--require spec_helper
--format documentation
```

`spec/spec_helper.rb`:
```ruby
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "shaolin/core"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
end
```

- [ ] **Step 6: Write `Rakefile`** `gems/shaolin-core/Rakefile`

```ruby
require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)
task default: :spec
```

- [ ] **Step 7: Install and verify**

Run (from repo root): `bundle install` then `cd gems/shaolin-core && bundle exec rspec`
Expected: bundle resolves; rspec runs 0 examples, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Gemfile gems/shaolin-core
git commit -m "feat(core): monorepo + shaolin-core gem skeleton"
```

---

## Task 1: Errors

**Files:** Create `gems/shaolin-core/lib/shaolin/errors.rb`, `spec/shaolin/errors_spec.rb`

- [ ] **Step 1: Failing test** `spec/shaolin/errors_spec.rb`

```ruby
require "shaolin/errors"

RSpec.describe "Shaolin errors" do
  it "ManifestError carries the offending module name" do
    err = Shaolin::ManifestError.new("bad", module_name: "users")
    expect(err.module_name).to eq("users")
    expect(err.message).to include("users")
  end

  it "IsolationError names consumer, key, and owner" do
    err = Shaolin::IsolationError.new(consumer: "users", key: "billing.secret", owner: "billing")
    expect(err.message).to include("users").and include("billing.secret").and include("billing")
  end
end
```

- [ ] **Step 2: Run, expect FAIL** — `bundle exec rspec spec/shaolin/errors_spec.rb` → uninitialized constant.

- [ ] **Step 3: Implement** `lib/shaolin/errors.rb`

```ruby
module Shaolin
  class Error < StandardError
    def to_contract
      { code: self.class.name.split("::").last, message: message }
    end
  end

  class ManifestError < Error
    attr_reader :module_name
    def initialize(msg, module_name: nil)
      @module_name = module_name
      super(module_name ? "[#{module_name}] #{msg}" : msg)
    end
  end

  class IsolationError < Error
    def initialize(consumer:, key:, owner:)
      super("module '#{consumer}' may not access '#{key}' (owned by '#{owner}'); add an import or use its exports")
    end
  end

  class BootError < Error; end
end
```

- [ ] **Step 4: Run, expect PASS.**

- [ ] **Step 5: Commit** — `git commit -am "feat(core): error types with machine-readable contract"`

---

## Task 2: Manifest value object + DSL

**Files:** Create `lib/shaolin/module_definition.rb`, `lib/shaolin/dsl.rb`, `spec/shaolin/dsl_spec.rb`; modify `lib/shaolin/core.rb` to require them.

- [ ] **Step 1: Failing test** `spec/shaolin/dsl_spec.rb`

```ruby
require "shaolin/core"

RSpec.describe Shaolin do
  it "builds a ModuleDefinition from the block" do
    defn = Shaolin.module("users") do
      imports "notifications.mailer"
      exports "user_service", "queries.find_user"
      commands_handled "RegisterUser"
      events_published "users.user_registered"
    end

    expect(defn.name).to eq("users")
    expect(defn.imports).to eq(["notifications.mailer"])
    expect(defn.exports).to eq(["user_service", "queries.find_user"])
    expect(defn.commands_handled).to eq(["RegisterUser"])
    expect(defn.events_published).to eq(["users.user_registered"])
  end

  it "accepts event subscriptions via imports(events:)" do
    defn = Shaolin.module("users") { imports events: ["billing.invoice_paid"] }
    expect(defn.subscribed_events).to eq(["billing.invoice_paid"])
  end
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** `lib/shaolin/module_definition.rb`

```ruby
module Shaolin
  class ModuleDefinition
    attr_reader :name, :imports, :exports, :commands_handled, :events_published, :subscribed_events

    def initialize(name)
      @name = name.to_s
      @imports = []
      @exports = []
      @commands_handled = []
      @events_published = []
      @subscribed_events = []
    end

    # DSL methods (called inside the block)
    def imports(*keys, events: [])
      @imports.concat(keys.flatten.map(&:to_s))
      @subscribed_events.concat(Array(events).map(&:to_s))
    end

    def exports(*keys)         = @exports.concat(keys.flatten.map(&:to_s))
    def commands_handled(*c)   = @commands_handled.concat(c.flatten.map(&:to_s))
    def events_published(*e)   = @events_published.concat(e.flatten.map(&:to_s))
  end
end
```

> Note: the reader methods and DSL methods share names; since the DSL methods append and the
> readers are only meaningful after the block runs, expose dedicated readers to avoid ambiguity.
> Adjust per the failing test: add `attr_reader`-style accessors that return the arrays, and have
> the DSL append only when given arguments. Implement so the spec passes (read with no args returns
> the array; with args appends).

- [ ] **Step 4: Refine implementation so read-vs-append works** — make each accessor: `def exports(*keys); return @exports if keys.empty?; @exports.concat(...); end`. Re-run until green.

- [ ] **Step 5: Implement DSL** `lib/shaolin/dsl.rb`

```ruby
require_relative "module_definition"

module Shaolin
  def self.module(name, &block)
    defn = ModuleDefinition.new(name)
    defn.instance_eval(&block) if block
    Registry.register(defn) if defined?(Registry)
    defn
  end
end
```

- [ ] **Step 6: Require from `core.rb`** — add `require_relative "errors"`, `require_relative "dsl"`.

- [ ] **Step 7: Run, expect PASS.**

- [ ] **Step 8: Commit** — `git commit -am "feat(core): module manifest DSL + ModuleDefinition"`

---

## Task 3: Registry

**Files:** Create `lib/shaolin/registry.rb`, `spec/shaolin/registry_spec.rb`; require from `core.rb`.

- [ ] **Step 1: Failing test** `spec/shaolin/registry_spec.rb`

```ruby
require "shaolin/core"

RSpec.describe Shaolin::Registry do
  before { Shaolin::Registry.reset! }

  it "registers and finds modules by name" do
    defn = Shaolin.module("users") { exports "user_service" }
    expect(Shaolin::Registry.find("users")).to be(defn)
    expect(Shaolin::Registry.names).to eq(["users"])
  end

  it "rejects duplicate module names" do
    Shaolin.module("users") {}
    expect { Shaolin.module("users") {} }.to raise_error(Shaolin::ManifestError, /users/)
  end
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** `lib/shaolin/registry.rb`

```ruby
require_relative "errors"

module Shaolin
  module Registry
    @modules = {}

    class << self
      def register(defn)
        if @modules.key?(defn.name)
          raise ManifestError.new("module already registered", module_name: defn.name)
        end
        @modules[defn.name] = defn
      end

      def find(name) = @modules[name.to_s]
      def names      = @modules.keys
      def all        = @modules.values
      def reset!     = @modules = {}
    end
  end
end
```

- [ ] **Step 4: Require from `core.rb`** (before `dsl` so `Registry` is defined when DSL references it).

- [ ] **Step 5: Run, expect PASS.**

- [ ] **Step 6: Commit** — `git commit -am "feat(core): module registry with duplicate detection"`

---

## Task 4: Config (dry-configurable, ENV-sourced)

**Files:** Create `lib/shaolin/config.rb`, `spec/shaolin/config_spec.rb`.

- [ ] **Step 1: Failing test** `spec/shaolin/config_spec.rb`

```ruby
require "shaolin/core"

RSpec.describe Shaolin::Config do
  it "defaults modules_path and reads env" do
    cfg = Shaolin::Config.new(env: { "SHAOLIN_ENV" => "production" })
    expect(cfg.modules_path).to eq("app/modules")
    expect(cfg.env).to eq("production")
  end
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** `lib/shaolin/config.rb`

```ruby
require "dry/configurable"

module Shaolin
  class Config
    extend Dry::Configurable
    setting :modules_path, default: "app/modules"
    setting :env, default: "development"

    def initialize(env: ENV)
      self.class.config.modules_path = env.fetch("SHAOLIN_MODULES_PATH", "app/modules")
      self.class.config.env          = env.fetch("SHAOLIN_ENV", "development")
    end

    def modules_path = self.class.config.modules_path
    def env          = self.class.config.env
  end
end
```

> If dry-configurable's class-level singleton config conflicts with per-instance overrides in tests,
> switch to an instance-config pattern (`include Dry::Configurable`); follow the gem's current API
> when the test tells you. Make the spec pass.

- [ ] **Step 4: Require from `core.rb`; run, expect PASS.**

- [ ] **Step 5: Commit** — `git commit -am "feat(core): ENV-sourced typed config"`

---

## Task 5: Container builder (dry-system per module)

**Files:** Create `lib/shaolin/container_builder.rb`, `spec/support/tmp_app.rb`, `spec/shaolin/container_builder_spec.rb`.

- [ ] **Step 1: Test helper** `spec/support/tmp_app.rb`

```ruby
require "tmpdir"
require "fileutils"

module TmpApp
  def with_module(name, files)
    Dir.mktmpdir("shaolin") do |root|
      mod_dir = File.join(root, "app/modules", name)
      FileUtils.mkdir_p(mod_dir)
      files.each do |rel, content|
        path = File.join(mod_dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      yield root, mod_dir
    end
  end
end
```

- [ ] **Step 2: Failing test** `spec/shaolin/container_builder_spec.rb`

```ruby
require "shaolin/core"
require "support/tmp_app"

RSpec.describe Shaolin::ContainerBuilder do
  include TmpApp

  it "auto-registers a component from a module folder by convention" do
    with_module("users", {
      "user_service.rb" => <<~RUBY
        module Users
          class UserService
            def call = :ok
          end
        end
      RUBY
    }) do |_root, mod_dir|
      container = described_class.build(name: "users", dir: mod_dir)
      expect(container["user_service"]).to be_a(Users::UserService)
      expect(container["user_service"].call).to eq(:ok)
    end
  end
end
```

- [ ] **Step 3: Run, expect FAIL.**

- [ ] **Step 4: Implement** `lib/shaolin/container_builder.rb`

```ruby
require "dry/system/container"

module Shaolin
  module ContainerBuilder
    # Build an isolated dry-system container rooted at a module's folder.
    def self.build(name:, dir:)
      klass = Class.new(Dry::System::Container)
      klass.configure do |config|
        config.name = name.to_sym
        config.root = dir
        config.component_dirs.add "." do |dir_config|
          dir_config.namespaces.add_root(const: nil)
        end
      end
      klass.finalize!
      klass
    end
  end
end
```

> The `component_dirs` / namespace API is the dry-system surface most likely to differ from this
> sketch. When the test fails on it, open the installed dry-system docs/source and use the real
> API to auto-register `user_service.rb` → `"user_service"` resolving `Users::UserService`. Pin the
> exact incantation here once green.

- [ ] **Step 5: Iterate against the real gem until the test passes.**

- [ ] **Step 6: Commit** — `git commit -am "feat(core): per-module dry-system container builder"`

---

## Task 6: Injector (Deps)

**Files:** Create `lib/shaolin/injector.rb`, `spec/shaolin/injector_spec.rb`.

- [ ] **Step 1: Failing test** `spec/shaolin/injector_spec.rb`

```ruby
require "shaolin/core"
require "support/tmp_app"

RSpec.describe "Deps injection" do
  include TmpApp

  it "injects a registered component via Deps[...]" do
    with_module("users", {
      "greeter.rb"  => "module Users; class Greeter; def hi = 'hi'; end; end",
      "welcomer.rb" => <<~RUBY
        module Users
          class Welcomer
            include SHAOLIN_DEPS["greeter"]
            def call = greeter.hi
          end
        end
      RUBY
    }) do |_root, mod_dir|
      container = Shaolin::ContainerBuilder.build(name: "users", dir: mod_dir)
      deps = Shaolin::Injector.for(container)
      stub_const("SHAOLIN_DEPS", deps)   # the generated module uses its own Deps constant in real apps
      expect(container["welcomer"].call).to eq("hi")
    end
  end
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** `lib/shaolin/injector.rb`

```ruby
require "dry/auto_inject"

module Shaolin
  module Injector
    def self.for(container)
      Dry::AutoInject(container)
    end
  end
end
```

> If injection requires the container to be the resolver (not finalized class), adjust
> `ContainerBuilder` to expose the right object for `Dry::AutoInject`. Follow the gem; make it green.
> In real generated modules each module gets its own `Deps = Shaolin::Injector.for(container)`
> constant; the test simulates that via `stub_const`.

- [ ] **Step 4: Run, expect PASS.**

- [ ] **Step 5: Commit** — `git commit -am "feat(core): Deps injector over dry-auto_inject"`

---

## Task 7: Providers + ordering

**Files:** Create `lib/shaolin/provider.rb`, `spec/shaolin/provider_spec.rb`.

- [ ] **Step 1: Failing test** `spec/shaolin/provider_spec.rb`

```ruby
require "shaolin/core"

RSpec.describe Shaolin::Provider do
  before { Shaolin::Provider.reset! }

  it "starts providers in dependency order" do
    order = []
    Shaolin.register_provider(:cqrs, after: [:active_record]) { start { order << :cqrs } }
    Shaolin.register_provider(:active_record) { start { order << :active_record } }

    Shaolin::Provider.start_all
    expect(order).to eq([:active_record, :cqrs])
  end

  it "runs stop hooks in reverse order" do
    order = []
    Shaolin.register_provider(:a) { stop { order << :a } }
    Shaolin.register_provider(:b, after: [:a]) { stop { order << :b } }
    Shaolin::Provider.stop_all
    expect(order).to eq([:b, :a])
  end
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** `lib/shaolin/provider.rb`

```ruby
require_relative "errors"

module Shaolin
  class Provider
    @providers = {}

    Definition = Struct.new(:name, :after, :start_block, :stop_block, keyword_init: true)

    class DSL
      attr_reader :start_block, :stop_block
      def start(&blk) = @start_block = blk
      def stop(&blk)  = @stop_block = blk
    end

    class << self
      def register(name, after: [], &block)
        dsl = DSL.new
        dsl.instance_eval(&block) if block
        @providers[name] = Definition.new(
          name: name, after: Array(after),
          start_block: dsl.start_block, stop_block: dsl.stop_block
        )
      end

      def ordered
        resolved = []
        visiting = {}
        visit = lambda do |name|
          return if resolved.include?(name)
          raise BootError, "provider cycle at #{name}" if visiting[name]
          visiting[name] = true
          dep = @providers[name] or raise BootError, "unknown provider #{name}"
          dep.after.each { |d| visit.call(d) }
          visiting[name] = false
          resolved << name
        end
        @providers.keys.each { |n| visit.call(n) }
        resolved.map { |n| @providers[n] }
      end

      def start_all = ordered.each { |p| p.start_block&.call }
      def stop_all  = ordered.reverse.each { |p| p.stop_block&.call }
      def reset!    = @providers = {}
    end
  end

  def self.register_provider(name, after: [], &block)
    Provider.register(name, after: after, &block)
  end
end
```

- [ ] **Step 4: Run, expect PASS.**

- [ ] **Step 5: Commit** — `git commit -am "feat(core): provider lifecycle with dependency ordering"`

---

## Task 8: App composition root + boot lifecycle

**Files:** Create `lib/shaolin/app.rb`, `lib/shaolin/lifecycle.rb`, `spec/shaolin/app_spec.rb`.

- [ ] **Step 1: Failing test** `spec/shaolin/app_spec.rb`

```ruby
require "shaolin/core"
require "support/tmp_app"

RSpec.describe Shaolin::App do
  include TmpApp
  before { Shaolin::Registry.reset!; Shaolin::Provider.reset! }

  it "discovers modules under modules_path and boots them" do
    with_module("users", {
      "module.rb"    => 'Shaolin.module("users") { exports "user_service" }',
      "user_service.rb" => "module Users; class UserService; def call = :ok; end; end"
    }) do |root, _mod_dir|
      app = Shaolin::App.new(root: root)
      app.boot!
      expect(app.modules).to eq(["users"])
      expect(app["users"]["user_service"].call).to eq(:ok)
    end
  end
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** `lib/shaolin/lifecycle.rb` (discover → configure/validate → register → providers → wire → finalize)

```ruby
require_relative "registry"
require_relative "container_builder"
require_relative "provider"

module Shaolin
  class Lifecycle
    def initialize(root:, config:)
      @root = root
      @config = config
      @containers = {}
    end
    attr_reader :containers

    def boot!
      discover
      validate
      register_containers
      Provider.start_all
      wire
      self
    end

    def shutdown! = Provider.stop_all

    private

    def modules_dir = File.join(@root, @config.modules_path)

    def discover
      Dir.glob(File.join(modules_dir, "*", "module.rb")).sort.each { |f| require f }
    end

    def validate
      Registry.all.each do |defn|
        # exports referencing nonexistent components are caught after registration in wire;
        # here we only check structural issues (cycles handled by Provider).
      end
    end

    def register_containers
      Registry.all.each do |defn|
        dir = File.join(modules_dir, defn.name)
        @containers[defn.name] = ContainerBuilder.build(name: defn.name, dir: dir)
      end
    end

    def wire
      # imports/exports wiring implemented in Task 9
    end
  end
end
```

`lib/shaolin/app.rb`:
```ruby
require_relative "config"
require_relative "lifecycle"

module Shaolin
  class App
    def initialize(root:, env: ENV)
      @root = root
      @config = Config.new(env: env)
      @lifecycle = Lifecycle.new(root: root, config: @config)
    end

    def boot!     = (@lifecycle.boot!; self)
    def shutdown! = @lifecycle.shutdown!
    def modules   = Registry.names
    def [](name)  = @lifecycle.containers.fetch(name.to_s)
  end
end
```

- [ ] **Step 4: Require `app` from `core.rb`; run, expect PASS.**

- [ ] **Step 5: Commit** — `git commit -am "feat(core): App composition root + boot lifecycle"`

---

## Task 9: Imports/exports wiring + isolation enforcement

**Files:** Modify `lib/shaolin/lifecycle.rb`; create `spec/shaolin/isolation_spec.rb`.

- [ ] **Step 1: Failing test** `spec/shaolin/isolation_spec.rb`

```ruby
require "shaolin/core"
require "support/tmp_app"

RSpec.describe "module isolation" do
  include TmpApp
  before { Shaolin::Registry.reset!; Shaolin::Provider.reset! }

  it "lets a module resolve an imported export of another module" do
    Dir.mktmpdir do |root|
      mk = ->(name, files) {
        d = File.join(root, "app/modules", name); FileUtils.mkdir_p(d)
        files.each { |f, c| File.write(File.join(d, f), c) }
      }
      mk.call("mailer", {
        "module.rb"  => 'Shaolin.module("mailer") { exports "mailer" }',
        "mailer.rb"  => "module Mailer; class Mailer; def send = :sent; end; end"
      })
      mk.call("users", {
        "module.rb"  => 'Shaolin.module("users") { imports "mailer.mailer" }',
        "notifier.rb"=> "module Users; class Notifier; end; end"
      })

      app = Shaolin::App.new(root: root).boot!
      expect(app["users"]["mailer.mailer"].send).to eq(:sent)
    end
  end

  it "raises IsolationError when resolving a non-imported key" do
    Dir.mktmpdir do |root|
      d = File.join(root, "app/modules", "users"); FileUtils.mkdir_p(d)
      File.write(File.join(d, "module.rb"), 'Shaolin.module("users") {}')
      app = Shaolin::App.new(root: root).boot!
      expect { app["users"]["mailer.mailer"] }.to raise_error(Shaolin::IsolationError, /mailer\.mailer/)
    end
  end
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement `wire` in `lifecycle.rb`** using dry-system imports

```ruby
def wire
  Registry.all.each do |defn|
    consumer = @containers[defn.name]
    defn.imports.each do |key|
      owner_name, export_key = split_key(key)
      owner = @containers[owner_name] or
        raise ManifestError.new("imports unknown module '#{owner_name}'", module_name: defn.name)
      unless Registry.find(owner_name).exports.include?(export_key)
        raise IsolationError.new(consumer: defn.name, key: key, owner: owner_name)
      end
      register_import(consumer, key, owner, export_key)
    end
  end
end

def split_key(key)
  owner, rest = key.split(".", 2)
  [owner, rest]
end

def register_import(consumer, key, owner, export_key)
  consumer.register(key) { owner[export_key] }
end
```

> The cleanest mechanism may be dry-system's native `import` rather than a manual `register`
> delegating to the owner. Use whichever the installed dry-system supports for cross-container
> resolution; the test pins the behavior (imported key resolves; non-imported raises IsolationError).
> For the "non-imported raises" case, wrap container `[]` access so unknown/unexported keys raise
> `IsolationError` — add a thin `Shaolin`-owned resolver around the dry-system container if needed.

- [ ] **Step 4: Iterate against the real gem until both examples pass.**

- [ ] **Step 5: Commit** — `git commit -am "feat(core): imports/exports wiring + isolation enforcement"`

---

## Task 10: README + green suite + tag

**Files:** Create `gems/shaolin-core/README.md`.

- [ ] **Step 1:** Write a concise README documenting `Shaolin.module`, `App#boot!`, `Deps`, providers, and the isolation contract (link the spec).
- [ ] **Step 2:** Run full suite: `bundle exec rspec` — expected: all green.
- [ ] **Step 3: Commit** — `git commit -am "docs(core): README; shaolin-core foundation complete"`

---

## Self-Review

- **Spec coverage:** Tasks map to spec §5 (DSL, T2), §6 (container/keys, T5/T6), §7 (lifecycle/providers, T7/T8), §8 (public API, T2–T9), §9 (errors, T1/T9). Config §10 → T4. Event-subscription handoff (§13) is declared in the manifest (T2) and consumed later by shaolin-cqrs — out of scope here, correctly.
- **Placeholders:** dry-system `component_dirs`/`import` blocks are flagged as "verify against installed gem" rather than guessed-final — TDD resolves them; this is honest, not a placeholder TODO.
- **Type consistency:** `ModuleDefinition` accessors, `ContainerBuilder.build(name:, dir:)`, `Injector.for`, `Provider.register/start_all/stop_all`, `App#boot!/#[]/#modules` are used consistently across tasks.

## Definition of Done (production bar for shaolin-core)

- All tasks green; `bundle exec rspec` 100% pass with no pending.
- No file > ~150 lines; each class one responsibility.
- dry-system API calls confirmed against the installed gem (no guessed APIs remain).
- Errors expose the `{code,message,...}` contract for LLM-friendliness.
- README present.

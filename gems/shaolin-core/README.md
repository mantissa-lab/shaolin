# shaolin-core

The kernel of the [shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-framework-design.md)
framework: modular dependency injection and a provider-based boot lifecycle over
[dry-system](https://hanakai.org/learn/dry/dry-system), with an enforced module-isolation contract.

## What it does

- **Discovers modules** under `app/modules/*/module.rb`.
- **Builds one dry-system container per module**, auto-registering components by convention
  (`user_service.rb` → key `"user_service"`, const `Users::UserService`;
  `queries/find_user.rb` → key `"queries.find_user"`).
- **Enforces isolation**: a module resolves only its own components and the keys it explicitly
  `imports`; only its `exports` are visible to others. Violations raise `Shaolin::IsolationError`.
- **Boots providers in dependency order** — HTTP, ActiveRecord, CQRS, Kafka, etc. plug in via
  `Shaolin.register_provider` and never touch the kernel's internals.

## Module manifest

```ruby
# app/modules/users/module.rb
Shaolin.module "users" do
  imports "notifications.mailer"
  imports events: ["billing.invoice_paid"]
  exports "user_service", "queries.find_user"
  commands_handled "RegisterUser"
  events_published "users.user_registered"
end
```

The manifest is the single source of truth for a module's public boundary — the contract an
owning agent reads first.

## Booting

```ruby
app = Shaolin::App.new(root: Dir.pwd).boot!
app.modules                       # => ["users", ...]
app["users"]["user_service"]      # resolved from the users container
app["users"]["notifications.mailer"]  # resolved via declared import
app.shutdown!                     # runs provider stop hooks in reverse order
```

## Dependency injection

Each module gets a `Deps` mixin bound to its container:

```ruby
Deps = Shaolin::Injector.for(container)

class UserService
  include Deps["user_repository"]
  def call(*) = user_repository.all
end
```

Dependencies arrive as keyword arguments and are overridable in tests
(`UserService.new(user_repository: fake)`).

## Errors

All errors expose a machine-readable contract (`#to_contract` → `{ code:, message: }`) for
LLM/agent tooling: `Shaolin::ManifestError`, `Shaolin::IsolationError`, `Shaolin::BootError`.

## Development

```bash
bundle install
cd gems/shaolin-core && bundle exec rspec
```

Built test-first. See the [design spec](../../docs/superpowers/specs/2026-06-03-shaolin-core-design.md).

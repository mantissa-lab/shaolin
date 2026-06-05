require_relative "lib/shaolin/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin"
  spec.version     = Shaolin::VERSION
  spec.summary     = "shaolin: a modular CQRS/ES Ruby framework (umbrella gem)"
  spec.description = "Meta-gem that pulls the full shaolin stack — kernel, CQRS/ES, " \
                     "ActiveRecord, DTOs, HTTP, server, jobs/outbox, messaging, Redis, " \
                     "RabbitMQ, LLM, and harness — plus the `shaolin` CLI. `require \"shaolin\"`."
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  # Pin every sub-gem to exactly this version so the framework moves in lockstep.
  v = Shaolin::VERSION
  spec.add_dependency "shaolin-core",         v
  spec.add_dependency "shaolin-dto",          v
  spec.add_dependency "shaolin-cqrs",         v
  spec.add_dependency "shaolin-activerecord", v
  spec.add_dependency "shaolin-http",         v
  spec.add_dependency "shaolin-server",       v
  spec.add_dependency "shaolin-messaging",    v
  spec.add_dependency "shaolin-jobs",         v
  spec.add_dependency "shaolin-redis",        v
  spec.add_dependency "shaolin-rabbitmq",     v
  spec.add_dependency "shaolin-llm",          v
  spec.add_dependency "shaolin-harness",      v
  spec.add_dependency "shaolin-cli",          v

  spec.add_development_dependency "rspec", "~> 3.13"
end

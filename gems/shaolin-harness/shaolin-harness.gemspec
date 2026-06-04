require_relative "lib/shaolin/harness/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-harness"
  spec.version     = Shaolin::Harness::VERSION
  spec.summary     = "shaolin LLM harness: event-sourced gate state machines (durable, auditable, replayable)"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"] + ["README.md"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "shaolin-cqrs"
  spec.add_dependency "shaolin-jobs"
  spec.add_dependency "shaolin-llm"
end

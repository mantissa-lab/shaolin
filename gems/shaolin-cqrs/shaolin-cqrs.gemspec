require_relative "lib/shaolin/cqrs/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-cqrs"
  spec.version     = Shaolin::CQRS::VERSION
  spec.summary     = "shaolin CQRS/ES building blocks over ruby_event_store"
  spec.authors     = ["shaolin"]
  spec.license     = "Nonstandard" # Mantissa Proprietary — see LICENSE
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "ruby_event_store", "~> 2.17"
  spec.add_dependency "aggregate_root", "~> 2.19"
  spec.add_dependency "arkency-command_bus", "~> 0.4"
  spec.add_dependency "dry-monads", "~> 1.6"
end

require_relative "lib/shaolin/core/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-core"
  spec.version     = Shaolin::Core::VERSION
  spec.summary     = "shaolin kernel: modular DI + lifecycle over dry-system"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "dry-system", "~> 1.0"
  spec.add_dependency "dry-auto_inject", "~> 1.0"
  spec.add_dependency "dry-configurable", "~> 1.0"
  spec.add_dependency "dry-inflector", "~> 1.0"

  spec.add_development_dependency "rspec", "~> 3.13"
end

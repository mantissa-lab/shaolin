require_relative "lib/shaolin/dto/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-dto"
  spec.version     = Shaolin::DTO_VERSION
  spec.summary     = "shaolin boundary validation (dry-validation) + typed value objects"
  spec.authors     = ["shaolin"]
  spec.license     = "Nonstandard" # Mantissa Proprietary — see LICENSE
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "dry-validation", "~> 1.10"
  spec.add_dependency "dry-struct", "~> 1.6"
  spec.add_dependency "dry-types", "~> 1.7"
end

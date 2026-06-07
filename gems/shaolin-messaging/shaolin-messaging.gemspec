require_relative "lib/shaolin/messaging/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-messaging"
  spec.version     = Shaolin::Messaging::VERSION
  spec.summary     = "shaolin transport-agnostic messaging ports (integration events, publisher, reactor)"
  spec.authors     = ["shaolin"]
  spec.license     = "Nonstandard" # Mantissa Proprietary — see LICENSE
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
end

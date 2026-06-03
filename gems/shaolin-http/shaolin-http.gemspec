require_relative "lib/shaolin/http/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-http"
  spec.version     = Shaolin::HTTP::VERSION
  spec.summary     = "shaolin HTTP transport: controllers map requests to commands/queries"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "rack", "~> 3.0"
  spec.add_dependency "hanami-router", "~> 2.2"
end

require_relative "lib/shaolin/server/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-server"
  spec.version     = Shaolin::Server::VERSION
  spec.summary     = "shaolin web server adapters (Puma/Falcon) + lifecycle"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "rack", "~> 3.0"
  spec.add_dependency "puma", "~> 6.4"
  spec.add_dependency "falcon", ">= 0.47"
end

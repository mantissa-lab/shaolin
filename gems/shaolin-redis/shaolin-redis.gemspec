require_relative "lib/shaolin/redis/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-redis"
  spec.version     = Shaolin::Redis::VERSION
  spec.summary     = "shaolin Redis integration: cache, key-value store, and broker (Streams + Pub/Sub)"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "shaolin-messaging"
  spec.add_dependency "redis", "~> 5.4"
  spec.add_dependency "connection_pool", ">= 2.4"
end

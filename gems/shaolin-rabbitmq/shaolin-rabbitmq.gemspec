require_relative "lib/shaolin/rabbitmq/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-rabbitmq"
  spec.version     = Shaolin::RabbitMQ::VERSION
  spec.summary     = "shaolin RabbitMQ transport (bunny): publish/consume integration events"
  spec.authors     = ["shaolin"]
  spec.license     = "Nonstandard" # Mantissa Proprietary — see LICENSE
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "shaolin-messaging"
  spec.add_dependency "bunny", "~> 2.22"
end

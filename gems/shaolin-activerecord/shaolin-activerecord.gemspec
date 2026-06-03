require_relative "lib/shaolin/activerecord/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-activerecord"
  spec.version     = Shaolin::ActiveRecordIntegration::VERSION
  spec.summary     = "shaolin ActiveRecord integration: event-store backend + read models"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "activerecord", "~> 8.0"
  spec.add_dependency "pg", "~> 1.5"
  spec.add_dependency "ruby_event_store-active_record", "~> 2.17"
end

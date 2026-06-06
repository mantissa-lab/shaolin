require_relative "lib/shaolin/jobs/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-jobs"
  spec.version     = Shaolin::Jobs::VERSION
  spec.summary     = "shaolin transactional outbox: async reactors, worker, scheduler"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "shaolin-cqrs"
  spec.add_dependency "activerecord", "~> 8.0"
  spec.add_dependency "concurrent-ruby", "~> 1.3"
end

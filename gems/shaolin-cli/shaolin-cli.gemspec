require_relative "lib/shaolin/cli/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-cli"
  spec.version     = Shaolin::CLI::VERSION
  spec.summary     = "shaolin CLI: project + module generators and runners"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*", "exe/*"].select { |f| File.file?(f) }
  spec.bindir      = "exe"
  spec.executables = ["shaolin"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "thor", "~> 1.3"
end

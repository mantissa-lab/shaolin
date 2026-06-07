require_relative "lib/shaolin/llm/version"

Gem::Specification.new do |spec|
  spec.name        = "shaolin-llm"
  spec.version     = Shaolin::LLM::VERSION
  spec.summary     = "shaolin LLM port: chat-completion + tool-calling, with InMemory and OpenAI adapters"
  spec.authors     = ["shaolin"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/shaolin-rb/shaolin"
  spec.files       = Dir["lib/**/*.rb"] + ["README.md"]
  spec.required_ruby_version = ">= 4.0.0"

  spec.add_dependency "shaolin-core"
  spec.add_dependency "concurrent-ruby", "~> 1.3"
end

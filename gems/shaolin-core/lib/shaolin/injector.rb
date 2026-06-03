require "dry/auto_inject"

module Shaolin
  # Produces a dry-auto_inject mixin bound to a module's container. Each module
  # gets its own `Deps = Shaolin::Injector.for(container)`, so a class can
  # `include Deps["user_repository"]` and receive it via keyword injection
  # (overridable in tests).
  module Injector
    def self.for(container)
      Dry::AutoInject(container)
    end
  end
end

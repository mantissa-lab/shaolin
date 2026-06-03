require "shaolin/core"
require_relative "command_bus"
require_relative "query_bus"
require_relative "event_store"
require_relative "aggregate_repository"

module Shaolin
  module CQRS
    # Registers the `:cqrs` lifecycle provider, which builds the shared
    # command bus, query bus, event store, and aggregate repository at boot and
    # publishes them into the kernel container as `cqrs.*` (resolvable from any
    # module via Deps). The event-store backend is injected by shaolin-activerecord
    # (registered as `cqrs.event_store_backend`); absent one, it defaults to an
    # in-memory store (monolith/dev/test).
    def self.register_provider!
      Shaolin.register_provider(:cqrs, after: provider_dependencies) do
        start do
          event_store =
            if Shaolin::Kernel.key?("cqrs.event_store_backend")
              EventStore.build(repository: Shaolin::Kernel["cqrs.event_store_backend"])
            else
              EventStore.in_memory
            end

          Shaolin::Kernel.register("cqrs.event_store", event_store)
          Shaolin::Kernel.register("cqrs.command_bus", CommandBus.new)
          Shaolin::Kernel.register("cqrs.query_bus", QueryBus.new)
          Shaolin::Kernel.register("cqrs.aggregate_repository", AggregateRepository.new(event_store))
        end
      end
    end

    # The backend is provided by shaolin-activerecord's :active_record provider
    # when present; declaring the dependency is safe even if it isn't registered
    # (the kernel falls back to in-memory).
    def self.provider_dependencies = []
  end
end

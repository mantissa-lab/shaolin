require "shaolin/core"
require_relative "command_bus"
require_relative "query_bus"
require_relative "event_store"
require_relative "aggregate_repository"

module Shaolin
  module CQRS
    # Registers the `:cqrs` lifecycle provider, which builds the shared command
    # bus, query bus, event store, and aggregate repository at boot, publishes
    # them into the kernel as `cqrs.*`, and auto-wires each module's command
    # handlers and projections. The event-store backend is injected by
    # shaolin-activerecord (`cqrs.event_store_backend`); absent one, it defaults
    # to an in-memory store (monolith/dev/test).
    def self.register_provider!
      Shaolin.register_provider(:cqrs) do
        start do
          event_store =
            if Shaolin::Kernel.key?("cqrs.event_store_backend")
              EventStore.build(repository: Shaolin::Kernel["cqrs.event_store_backend"])
            else
              EventStore.in_memory
            end

          command_bus = CommandBus.new
          query_bus = QueryBus.new
          Shaolin::Kernel.register("cqrs.event_store", event_store)
          Shaolin::Kernel.register("cqrs.command_bus", command_bus)
          Shaolin::Kernel.register("cqrs.query_bus", query_bus)
          Shaolin::Kernel.register("cqrs.aggregate_repository", AggregateRepository.new(event_store))

          Shaolin::CQRS.wire_modules(command_bus, query_bus, event_store)
        end
      end
    end

    # Auto-register command + query handlers on their buses and subscribe
    # projections to the event store, by enumerating each module's components.
    def self.wire_modules(command_bus, query_bus, event_store)
      containers = Shaolin::Kernel.key?("kernel.containers") ? Shaolin::Kernel["kernel.containers"] : {}
      containers.each_value do |container|
        wire_command_handlers(container, command_bus)
        wire_query_handlers(container, query_bus)
        wire_projections(container, event_store)
      end
    end

    def self.wire_query_handlers(container, query_bus)
      container.keys.grep(/\Aquery_handlers\./).each do |key|
        handler = container[key]
        next unless handler.class.respond_to?(:handled_query) && handler.class.handled_query

        query_bus.register(handler.class.handled_query, handler)
      end
    end

    def self.wire_command_handlers(container, command_bus)
      container.keys.grep(/\Acommand_handlers\./).each do |key|
        handler = container[key]
        next unless handler.class.respond_to?(:handled_command) && handler.class.handled_command

        command_bus.register(handler.class.handled_command, handler)
      end
    end

    def self.wire_projections(container, event_store)
      container.keys.grep(/\Aprojections\./).each do |key|
        projection = container[key]
        next unless projection.class.respond_to?(:subscribed_events)

        events = projection.class.subscribed_events
        event_store.subscribe(projection, to: events) unless events.empty?
      end
    end
  end
end

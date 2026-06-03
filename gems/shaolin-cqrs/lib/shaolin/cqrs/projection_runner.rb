require "shaolin/core"

module Shaolin
  module CQRS
    # Rebuilds read models by replaying the event store through projections.
    # Read models are idempotent upserts, so replaying the full stream is safe
    # and deterministic.
    module ProjectionRunner
      # Replay the events a single projection subscribes to.
      def self.rebuild(event_store, projection)
        events = projection.class.subscribed_events
        return if events.empty?

        event_store.read.of_type(events).each { |event| projection.call(event) }
      end

      # Rebuild every module's projections from the kernel's event store + containers.
      def self.rebuild_all(only: nil)
        event_store = Shaolin::Kernel["cqrs.event_store"]
        containers.each do |module_name, container|
          next if only && only.to_s != module_name.to_s

          container.keys.grep(/\Aprojections\./).each { |key| rebuild(event_store, container[key]) }
        end
      end

      def self.containers
        Shaolin::Kernel.key?("kernel.containers") ? Shaolin::Kernel["kernel.containers"] : {}
      end
    end
  end
end

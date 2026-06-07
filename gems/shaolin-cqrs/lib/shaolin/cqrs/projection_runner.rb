require "shaolin/core"

module Shaolin
  module CQRS
    # Rebuilds read models by replaying the event store through projections.
    # Read models are idempotent upserts, so replaying the full stream is safe
    # and deterministic.
    module ProjectionRunner
      # Replay the events a single projection subscribes to. RES reads lazily in
      # pages, so memory stays bounded for a large stream. **Resumable**: pass
      # `after:` (an event id) to continue past a checkpoint, and use the returned
      # last-processed id as the next checkpoint — so a multi-million-event rebuild
      # can stop/restart instead of always replaying from zero.
      def self.rebuild(event_store, projection, after: nil)
        events = projection.class.subscribed_events
        return after if events.empty?

        spec = event_store.read.of_type(events)
        spec = spec.from(after) if after

        last = after
        spec.each do |event|
          projection.call(event)
          last = event.event_id
        end
        last
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

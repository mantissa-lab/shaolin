require "shaolin/core"
require_relative "schema"
require_relative "outbox"

module Shaolin
  module Jobs
    # The :jobs provider. Ensures the outbox table, registers `jobs.outbox`, and
    # auto-subscribes each module's reactors to the event store as ENQUEUE
    # callbacks: when a subscribed event is published, an outbox row is inserted
    # in the same transaction as the event append (transactional outbox). The
    # reactor's actual side effect runs later in `shaolin worker`.
    #
    # Register AFTER :active_record (needs the connection + schema) and :cqrs
    # (needs the shared event store).
    def self.register_provider!
      Shaolin.register_provider(:jobs) do
        start do
          Schema.create!
          outbox = Outbox.new
          Shaolin::Kernel.register("jobs.outbox", outbox)

          event_store = Shaolin::Kernel["cqrs.event_store"]
          Shaolin::Jobs.wire_reactors(event_store, outbox)
        end
      end
    end

    def self.wire_reactors(event_store, outbox)
      containers = Shaolin::Kernel.key?("kernel.containers") ? Shaolin::Kernel["kernel.containers"] : {}
      containers.each_value do |container|
        container.keys.grep(/\Areactors\./).each do |key|
          reactor = container[key]
          klass = reactor.class
          next unless klass.respond_to?(:subscribed_events)

          bind_topics(klass)

          events = klass.subscribed_events
          next if events.empty?

          reactor_name = klass.name
          enqueuer = ->(event) { outbox.enqueue(reactor: reactor_name, event: event) }
          event_store.subscribe(enqueuer, to: events)
        end
      end
    end

    # Resolve each string/topic subscription to a concrete (cross-module) event
    # class and bind the reactor's block under it, so the enqueue callback can
    # subscribe by class like the own-module form. Fail loud on a contract typo.
    def self.bind_topics(klass)
      return unless klass.respond_to?(:subscribed_topics)

      klass.subscribed_topics.each { |topic| klass.bind_topic(topic, resolve_event(topic)) }
    end

    def self.resolve_event(topic)
      name = Shaolin::Topic.event_class_name(topic)
      Object.const_get(name)
    rescue NameError => e
      raise Shaolin::Error,
            "reactor subscribes to topic #{topic.inspect}, but its event class #{name} is not defined (#{e.message})"
    end
  end
end

require "shaolin/core"

module Shaolin
  module Jobs
    # Base for async reactors (side effects: send email, publish to a broker,
    # call an external API). DX mirrors Shaolin::CQRS::Projection — declare
    # handlers with `on(...) { |event| ... }` — but the handler runs LATER in the
    # `shaolin worker` (via the outbox), NOT in the event's transaction.
    #
    # At-least-once delivery → handlers MUST be idempotent.
    #
    # Two subscription forms:
    #   on(UserRegistered) { |e| ... }                 # OWN module's event (class)
    #   on("billing.invoice_paid") { |e| ... }          # ANOTHER module's event by
    #                                                    # topic string — lint-clean,
    #                                                    # no cross-module constant.
    # The topic must be declared in this module's manifest as
    # `imports events: ["billing.invoice_paid"]`. The :jobs provider resolves the
    # topic to its event class at wire time and binds the block under that class,
    # so `call(event)` dispatch is identical for both forms.
    class Reactor
      # Cross-module reads use the same `import("other.key")` as controllers and
      # handlers — resolved via this reactor's OWN module container, validated
      # against the manifest, and checked statically by `shaolin lint`. Reactor
      # blocks run via `instance_exec`, so `import(...)` is in scope inside them.
      include Shaolin::Imports

      def self.on(event_or_topic, &block)
        if event_or_topic.is_a?(String)
          topic_handlers[event_or_topic] = block
        else
          handlers[event_or_topic] = block
        end
      end

      def self.handlers = (@handlers ||= {})
      def self.topic_handlers = (@topic_handlers ||= {})
      def self.subscribed_events = handlers.keys
      def self.subscribed_topics = topic_handlers.keys

      # Called by the provider at wire time: bind a topic's block under the
      # resolved event class so handlers[event.class] dispatch works uniformly.
      def self.bind_topic(topic, event_class)
        block = topic_handlers[topic]
        handlers[event_class] = block if block
      end

      # Run the side effect for an event (called by the worker).
      def call(event)
        block = self.class.handlers[event.class]
        instance_exec(event, &block) if block
      end
    end
  end
end

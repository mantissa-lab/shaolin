module Shaolin
  module Jobs
    # Base for async reactors (side effects: send email, publish to a broker,
    # call an external API). DX mirrors Shaolin::CQRS::Projection — declare
    # handlers with `on(EventClass) { |event| ... }` — but the handler runs LATER
    # in the `shaolin worker` (via the outbox), NOT in the event's transaction.
    #
    # At-least-once delivery → handlers MUST be idempotent.
    #
    #   class NotifyReactor < Shaolin::Jobs::Reactor
    #     on(UserRegistered) { |event| Mailer.welcome(event.data[:email]) }
    #   end
    class Reactor
      def self.on(event_class, &block)
        handlers[event_class] = block
      end

      def self.handlers = (@handlers ||= {})
      def self.subscribed_events = handlers.keys

      # Run the side effect for an event (called by the worker).
      def call(event)
        block = self.class.handlers[event.class]
        instance_exec(event, &block) if block
      end
    end
  end
end

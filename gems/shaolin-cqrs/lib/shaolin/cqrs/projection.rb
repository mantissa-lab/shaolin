module Shaolin
  module CQRS
    # Base for projections. Declare event handlers with `on`; the :cqrs provider
    # subscribes the projection to those events on the event store at boot. The
    # block runs in instance context, so it can write read models.
    #
    #   class UsersProjection < Shaolin::CQRS::Projection
    #     on UserRegistered do |event|
    #       UserRecord.project(id: event.data[:id]) { |r| r.email = event.data[:email] }
    #     end
    #   end
    class Projection
      def self.on(event_class, &block)
        handlers[event_class] = block
      end

      # Mark this projection ASYNC: NOT subscribed synchronously in the event
      # append transaction. The :jobs provider drives it through the outbox (the
      # worker runs it, at-least-once — its upserts are idempotent, so safe). The
      # read model is then EVENTUALLY consistent (a read right after the command
      # may not see it) in exchange for append-only write latency. Requires the
      # :jobs provider + a running `shaolin worker`. Sync is the default.
      def self.async = (@async = true)
      def self.async? = @async == true

      def self.handlers = (@handlers ||= {})
      def self.subscribed_events = handlers.keys

      # Called by ruby_event_store when a subscribed event is published.
      def call(event)
        block = self.class.handlers[event.class]
        instance_exec(event, &block) if block
      end
    end
  end
end

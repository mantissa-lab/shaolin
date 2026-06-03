require "json"
require "shaolin/messaging"

module Shaolin
  module Redis
    # Publishes integration events to a Redis Stream (XADD). Implements the
    # transport-agnostic Shaolin::Messaging::Publisher port, so it is a drop-in
    # swap for the RabbitMQ or in-memory publisher. Reactors publish through the
    # outbox, so delivery stays reliable across crashes; consumer groups on the
    # stream give at-least-once consumption with acks.
    #
    # `maxlen` caps the stream (approximate trim) so it can't grow unbounded.
    class StreamPublisher
      include Shaolin::Messaging::Publisher

      def initialize(pool:, stream: "shaolin:events", maxlen: 100_000)
        @pool = pool
        @stream = stream
        @maxlen = maxlen
      end

      def publish(integration_event)
        @pool.with do |r|
          r.xadd(
            @stream,
            { "event_type" => integration_event.event_type, "body" => integration_event.to_json },
            maxlen: @maxlen, approximate: true
          )
        end
        integration_event
      end
    end
  end
end

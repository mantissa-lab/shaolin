module Shaolin
  module Messaging
    # The outbound port. A concrete adapter (e.g. Kafka via WaterDrop) implements
    # `#publish(integration_event)`.
    module Publisher
      def publish(_integration_event)
        raise NotImplementedError, "#{self.class} must implement #publish"
      end
    end

    # In-process publisher used in monolith/dev/test: records what was published.
    class InMemoryPublisher
      include Publisher

      def initialize
        @published = []
      end

      attr_reader :published

      def publish(integration_event)
        @published << integration_event
        integration_event
      end
    end
  end
end

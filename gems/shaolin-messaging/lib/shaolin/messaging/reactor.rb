require_relative "integration_event"

module Shaolin
  module Messaging
    # Base for reactors: subscribe to a domain event and publish a curated
    # integration event. Declare the mapping with `publishes`.
    #
    #   class UserReactor < Shaolin::Messaging::Reactor
    #     publishes "users.user_registered" do |event|
    #       { id: event.data[:id], email: event.data[:email] }
    #     end
    #   end
    #
    #   UserReactor.new(publisher).call(domain_event)  # publishes the integration event
    class Reactor
      class << self
        attr_reader :integration_type, :mapper

        def publishes(integration_type, &mapper)
          @integration_type = integration_type
          @mapper = mapper
        end
      end

      def initialize(publisher, producer: nil)
        @publisher = publisher
        @producer = producer
      end

      def call(domain_event)
        payload = self.class.mapper ? self.class.mapper.call(domain_event) : domain_event.data
        @publisher.publish(
          IntegrationEvent.new(event_type: self.class.integration_type, payload: payload, producer: @producer)
        )
      end
    end
  end
end

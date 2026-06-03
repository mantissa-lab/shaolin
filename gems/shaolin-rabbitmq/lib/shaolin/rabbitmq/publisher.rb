require "json"
require "shaolin/messaging"

module Shaolin
  module RabbitMQ
    # Publishes integration events to a RabbitMQ topic exchange (routing key =
    # event_type). Implements the transport-agnostic `Shaolin::Messaging::Publisher`
    # port, so swapping in/out of RabbitMQ is a one-line adapter change. Inject an
    # `exchange` in tests; otherwise it lazily opens a bunny connection.
    class Publisher
      include Shaolin::Messaging::Publisher

      def initialize(exchange: nil, url: ENV["RABBITMQ_URL"], exchange_name: "shaolin")
        @exchange = exchange
        @url = url
        @exchange_name = exchange_name
      end

      def publish(integration_event)
        exchange.publish(integration_event.to_json, routing_key: integration_event.event_type)
        integration_event
      end

      private

      def exchange
        @exchange ||= begin
          require "bunny"
          session = ::Bunny.new(@url)
          session.start
          session.create_channel.topic(@exchange_name, durable: true)
        end
      end
    end
  end
end

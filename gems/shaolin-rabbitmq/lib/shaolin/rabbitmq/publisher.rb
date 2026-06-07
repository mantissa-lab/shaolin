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

      # `breaker:` (optional, a Shaolin::CircuitBreaker) fast-fails publishes during
      # a broker brownout instead of piling up doomed connections.
      def initialize(exchange: nil, url: ENV["RABBITMQ_URL"], exchange_name: "shaolin", breaker: nil)
        @exchange = exchange
        @url = url
        @exchange_name = exchange_name
        @breaker = breaker
      end

      def publish(integration_event)
        run { exchange.publish(integration_event.to_json, routing_key: integration_event.event_type) }
        integration_event
      end

      private

      def run(&block) = @breaker ? @breaker.call(&block) : block.call

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

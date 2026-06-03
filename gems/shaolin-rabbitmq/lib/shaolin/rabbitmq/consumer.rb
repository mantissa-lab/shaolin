require "json"

module Shaolin
  module RabbitMQ
    # Subscribes to a queue and yields each integration-event envelope (a Hash
    # with symbol keys). The app maps the envelope to a Command on the command
    # bus — the same write path as HTTP. Inject a `queue` in tests; otherwise use
    # `.connect` to build a bunny-backed queue bound to the exchange.
    class Consumer
      def self.connect(queue:, routing_keys:, url: ENV["RABBITMQ_URL"], exchange_name: "shaolin")
        require "bunny"
        session = ::Bunny.new(url)
        session.start
        channel = session.create_channel
        exchange = channel.topic(exchange_name, durable: true)
        q = channel.queue(queue, durable: true)
        routing_keys.each { |key| q.bind(exchange, routing_key: key) }
        new(queue: q)
      end

      def initialize(queue:)
        @queue = queue
      end

      # Subscribe and yield each parsed envelope. Blocks (use in a worker process).
      def run
        @queue.subscribe(block: true) do |_delivery_info, _properties, body|
          yield parse(body)
        end
      end

      def parse(body)
        JSON.parse(body, symbolize_names: true)
      end
    end
  end
end

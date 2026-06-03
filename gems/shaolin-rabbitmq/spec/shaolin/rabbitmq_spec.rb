require "shaolin/rabbitmq"
require "shaolin/messaging"
require "json"

RSpec.describe Shaolin::RabbitMQ do
  describe Shaolin::RabbitMQ::Publisher do
    it "publishes the integration-event JSON with routing key = event_type" do
      exchange = Class.new do
        attr_reader :published
        def initialize = (@published = [])
        def publish(payload, routing_key:) = (@published << [payload, routing_key])
      end.new

      publisher = described_class.new(exchange: exchange)
      event = Shaolin::Messaging::IntegrationEvent.new(event_type: "users.user_registered", payload: { id: "u1" })
      publisher.publish(event)

      payload, routing_key = exchange.published.first
      expect(routing_key).to eq("users.user_registered")
      expect(JSON.parse(payload)).to include("event_type" => "users.user_registered", "payload" => { "id" => "u1" })
    end

    it "is a Shaolin::Messaging::Publisher (drop-in for the in-memory one)" do
      expect(described_class.new(exchange: Object.new)).to be_a(Shaolin::Messaging::Publisher)
    end
  end

  describe Shaolin::RabbitMQ::Consumer do
    it "yields the parsed envelope for each delivered message" do
      body = JSON.generate(event_type: "billing.invoice_paid", payload: { id: "i1" })
      queue = Class.new do
        def initialize(body) = (@body = body)
        def subscribe(block:) = (yield(nil, nil, @body))
      end.new(body)

      seen = []
      described_class.new(queue: queue).run { |env| seen << env }

      expect(seen.first).to eq(event_type: "billing.invoice_paid", payload: { id: "i1" })
    end
  end
end

require "shaolin/messaging"
require "json"

RSpec.describe Shaolin::Messaging do
  describe Shaolin::Messaging::IntegrationEvent do
    it "round-trips to_h and to_json" do
      event = described_class.new(event_type: "users.user_registered", payload: { id: "u1" }, correlation_id: "c1")
      expect(event.to_h).to include(event_type: "users.user_registered", schema_version: 1, payload: { id: "u1" })
      expect(JSON.parse(event.to_json)["event_type"]).to eq("users.user_registered")
    end
  end

  describe Shaolin::Messaging::InMemoryPublisher do
    it "records published events" do
      publisher = described_class.new
      event = Shaolin::Messaging::IntegrationEvent.new(event_type: "x.y")
      publisher.publish(event)
      expect(publisher.published).to eq([event])
    end
  end

  describe Shaolin::Messaging::Reactor do
    it "maps a domain event to a curated integration event and publishes it" do
      reactor_class = Class.new(described_class) do
        publishes("users.user_registered") { |event| { id: event.data[:id] } }
      end
      domain_event = Struct.new(:data).new({ id: "u1", secret: "hidden" })
      publisher = Shaolin::Messaging::InMemoryPublisher.new

      reactor_class.new(publisher).call(domain_event)

      published = publisher.published.first
      expect(published.event_type).to eq("users.user_registered")
      expect(published.payload).to eq({ id: "u1" }) # curated — internal :secret not leaked
    end
  end

  describe ".topic_for" do
    it "uses the event_type as the topic name" do
      event = Shaolin::Messaging::IntegrationEvent.new(event_type: "billing.invoice_paid")
      expect(described_class.topic_for(event)).to eq("billing.invoice_paid")
      expect(described_class.topic_for("a.b")).to eq("a.b")
    end
  end
end

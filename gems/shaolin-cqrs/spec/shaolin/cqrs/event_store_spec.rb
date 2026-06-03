require "shaolin/cqrs"

class Pinged < RubyEventStore::Event; end

RSpec.describe Shaolin::CQRS::EventStore do
  it "in_memory publishes events and notifies subscribers" do
    store = described_class.in_memory
    seen = []
    store.subscribe(->(event) { seen << event.data[:x] }, to: [Pinged])

    store.publish(Pinged.new(data: { x: 1 }), stream_name: "S$1")
    expect(seen).to eq([1])
  end
end

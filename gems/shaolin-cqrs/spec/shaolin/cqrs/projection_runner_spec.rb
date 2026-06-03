require "shaolin/cqrs"

class Bumped2 < RubyEventStore::Event; end

class RecordingProjection < Shaolin::CQRS::Projection
  on(Bumped2) { |event| $rebuilt_seen << event.data[:n] }
end

RSpec.describe Shaolin::CQRS::ProjectionRunner do
  it "rebuilds a read model by replaying the event store" do
    $rebuilt_seen = []
    store = Shaolin::CQRS::EventStore.in_memory
    store.publish(Bumped2.new(data: { n: 1 }), stream_name: "X$1")
    store.publish(Bumped2.new(data: { n: 2 }), stream_name: "X$2")

    expect($rebuilt_seen).to eq([]) # nothing was subscribed live

    described_class.rebuild(store, RecordingProjection.new)

    expect($rebuilt_seen).to eq([1, 2]) # replayed from the store
  end
end

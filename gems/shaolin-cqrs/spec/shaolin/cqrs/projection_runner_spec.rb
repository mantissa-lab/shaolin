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

    last = described_class.rebuild(store, RecordingProjection.new)

    expect($rebuilt_seen).to eq([1, 2]) # replayed from the store
    expect(last).to be_a(String) # returns the last-processed event id (a checkpoint)
  end

  it "#26 resumes from a checkpoint: rebuild(after:) replays only newer events" do
    $rebuilt_seen = []
    store = Shaolin::CQRS::EventStore.in_memory
    e1 = Bumped2.new(data: { n: 1 })
    store.publish(e1, stream_name: "X$1")
    store.publish(Bumped2.new(data: { n: 2 }), stream_name: "X$2")
    store.publish(Bumped2.new(data: { n: 3 }), stream_name: "X$3")

    last = described_class.rebuild(store, RecordingProjection.new, after: e1.event_id)

    expect($rebuilt_seen).to eq([2, 3]) # only events after the checkpoint
    expect(last).not_to eq(e1.event_id) # advanced the checkpoint
  end
end

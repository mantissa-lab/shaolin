require "shaolin/activerecord"
require "support/pg"

RSpec.describe "event store backend (AR)" do
  before { PgTest.reset_schema! }

  describe Shaolin::AR::EventStoreSchema do
    it "creates and drops the event-store tables, idempotently" do
      described_class.create!
      expect(described_class.exists?).to be(true)
      tables = ActiveRecord::Base.connection.tables
      expect(tables).to include("event_store_events", "event_store_events_in_streams")

      expect { described_class.create! }.not_to raise_error # idempotent

      described_class.drop!
      expect(described_class.exists?).to be(false)
    end
  end

  describe "Shaolin::AR.event_repository" do
    it "persists and reads events with symbol-key round-trip" do
      Shaolin::AR::EventStoreSchema.create!
      client = RubyEventStore::Client.new(repository: Shaolin::AR.event_repository)

      stub_const("Probed", Class.new(RubyEventStore::Event))
      client.publish(Probed.new(data: { msg: "hi", n: 2 }), stream_name: "Probe$1")

      read = client.read.stream("Probe$1").to_a
      expect(read.size).to eq(1)
      expect(read.first.data).to eq(msg: "hi", n: 2)
    end

    it "preserves symbol keys for NESTED event data (no string keys creep in)" do
      Shaolin::AR::EventStoreSchema.create!
      client = RubyEventStore::Client.new(repository: Shaolin::AR.event_repository)
      stub_const("NestedProbed", Class.new(RubyEventStore::Event))

      client.publish(
        NestedProbed.new(data: { id: "a1", attribution: { source: "ad", tags: [{ k: "v" }] } }),
        stream_name: "Nested$1"
      )

      data = client.read.stream("Nested$1").to_a.first.data
      expect(data).to eq(id: "a1", attribution: { source: "ad", tags: [{ k: "v" }] })
      expect(data[:attribution][:tags].first.keys).to eq([:k]) # symbols, not strings
    end
  end
end

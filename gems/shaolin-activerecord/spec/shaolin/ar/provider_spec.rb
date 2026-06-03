require "shaolin/activerecord"
require "shaolin/cqrs"
require "support/pg"

RSpec.describe "shaolin-activerecord :active_record provider" do
  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    PgTest.reset_schema!
  end

  it "registers a durable event-store backend that :cqrs uses end-to-end" do
    # Order matters: activerecord before cqrs.
    Shaolin::AR.register_provider!(config: PgTest::CONFIG)
    Shaolin::CQRS.register_provider!
    Shaolin::Provider.start_all

    backend = Shaolin::Kernel["cqrs.event_store_backend"]
    expect(backend).to be_a(RubyEventStore::ActiveRecord::PgLinearizedEventRepository)

    store = Shaolin::Kernel["cqrs.event_store"]
    stub_const("ThingHappened", Class.new(RubyEventStore::Event))
    store.publish(ThingHappened.new(data: { v: 1 }), stream_name: "Thing$1")

    # A fresh client over the same durable backend sees the persisted event
    # (proves durability, not in-memory).
    fresh = RubyEventStore::Client.new(repository: Shaolin::AR.event_repository)
    expect(fresh.read.stream("Thing$1").to_a.map { |e| e.data[:v] }).to eq([1])
  end
end

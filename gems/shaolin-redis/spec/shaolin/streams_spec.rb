require "spec_helper"

RSpec.describe "Redis Streams broker" do
  let(:pool) { Shaolin::Redis::Connection.pool(url: REDIS_TEST_URL) }
  let(:stream) { "t:events" }
  let(:publisher) { Shaolin::Redis::StreamPublisher.new(pool: pool, stream: stream) }

  def consumer(name)
    Shaolin::Redis::StreamConsumer.new(pool: pool, stream: stream, group: "g1", consumer: name, block_ms: 100)
  end

  def event(type, payload)
    Shaolin::Messaging::IntegrationEvent.new(event_type: type, payload: payload)
  end

  it "publishes via the Messaging::Publisher port" do
    expect(publisher).to be_a(Shaolin::Messaging::Publisher)
  end

  it "delivers a published event to a consumer group, then acks it" do
    con = consumer("c1")
    con.ensure_group! # subscribe to new messages before publishing
    publisher.publish(event("users.user_registered", id: "u1"))

    seen = []
    n = con.poll { |env| seen << env }

    expect(n).to eq(1)
    expect(seen.first[:event_type]).to eq("users.user_registered")
    expect(seen.first[:payload]).to eq(id: "u1")
    # acked → nothing pending on a second poll
    expect(con.poll { |_| raise "should not redeliver" }).to eq(0)
  end

  it "two consumers in a group split the load (no double-processing)" do
    a = consumer("a")
    a.ensure_group!
    3.times { |i| publisher.publish(event("e", n: i)) }

    seen = []
    consumer("a").poll { |env| seen << env }
    consumer("b").poll { |env| seen << env }
    expect(seen.map { |e| e[:payload][:n] }.sort).to eq([0, 1, 2])
  end

  it "reclaims un-acked entries from a crashed consumer (XAUTOCLAIM)" do
    a = consumer("a")
    a.ensure_group!
    publisher.publish(event("e", id: "x"))

    # consumer "a" reads but crashes before acking (raw read, no ack)
    pool.with { |r| r.xreadgroup("g1", "a", stream, ">", count: 10) }

    seen = []
    reclaimed = consumer("b").reclaim(idle_ms: 0) { |env| seen << env }
    expect(reclaimed).to eq(1)
    expect(seen.first[:payload]).to eq(id: "x")
  end
end

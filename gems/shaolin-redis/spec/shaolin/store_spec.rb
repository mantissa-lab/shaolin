require "spec_helper"

RSpec.describe Shaolin::Redis::Store do
  let(:pool) { Shaolin::Redis::Connection.pool(url: REDIS_TEST_URL) }
  subject(:store) { described_class.new(pool: pool, namespace: "t:store") }

  it "stores and fetches JSON documents (symbol keys on read)" do
    store.set("user:1", { id: "1", name: "Neo" })
    expect(store.get("user:1")).to eq(id: "1", name: "Neo")
    expect(store.exists?("user:1")).to be(true)
  end

  it "deletes" do
    store.set("k", 1)
    store.delete("k")
    expect(store.exists?("k")).to be(false)
  end

  it "increments and decrements native counters" do
    expect(store.increment("hits")).to eq(1)
    expect(store.increment("hits", by: 4)).to eq(5)
    expect(store.decrement("hits", by: 2)).to eq(3)
  end

  it "sets a TTL on first increment (fixed-window counter for rate limits)" do
    expect(store.increment("win", ttl: 60)).to eq(1)
    ttl = pool.with { |r| r.ttl("t:store:win") }
    expect(ttl).to be > 0
    expect(ttl).to be <= 60
  end

  it "supports hash fields as a 'row' with JSON values" do
    store.hset("session:abc", "user_id", "u-1")
    store.hset("session:abc", "roles", %w[admin editor])
    expect(store.hget("session:abc", "roles")).to eq(%w[admin editor])
    expect(store.hgetall("session:abc")).to eq(user_id: "u-1", roles: %w[admin editor])
  end

  it "lists its own keys without the namespace prefix" do
    store.set("a", 1)
    store.set("b", 2)
    expect(store.keys.sort).to eq(%w[a b])
  end
end

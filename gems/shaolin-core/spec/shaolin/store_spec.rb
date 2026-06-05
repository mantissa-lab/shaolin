require "shaolin/core"

RSpec.describe Shaolin::Store::Memory do
  subject(:store) { described_class.new }

  it "is a Shaolin::Store (swappable for Redis::Store)" do
    expect(store).to be_a(Shaolin::Store)
  end

  it "round-trips JSON values with symbol keys" do
    store.set("user:1", { id: "1", name: "Neo" })
    expect(store.get("user:1")).to eq(id: "1", name: "Neo")
    expect(store.exists?("user:1")).to be(true)
    expect(store.get("missing")).to be_nil
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

  it "supports hash fields with JSON values (symbol keys)" do
    store.hset("session:a", "user_id", "u1")
    store.hset("session:a", "roles", %w[admin])
    expect(store.hget("session:a", "roles")).to eq(%w[admin])
    expect(store.hgetall("session:a")).to eq(user_id: "u1", roles: %w[admin])
  end

  it "lists keys by glob pattern" do
    store.set("user:1", 1)
    store.set("user:2", 2)
    store.set("post:1", 3)
    expect(store.keys("user:*").sort).to eq(%w[user:1 user:2])
  end
end

require "spec_helper"

RSpec.describe Shaolin::Redis::Cache do
  let(:pool) { Shaolin::Redis::Connection.pool(url: REDIS_TEST_URL) }
  subject(:cache) { described_class.new(pool: pool, namespace: "t:cache") }

  it "is a Shaolin::Cache (swappable for the in-memory port)" do
    expect(cache).to be_a(Shaolin::Cache)
  end

  it "round-trips JSON values with symbol keys (matching the rest of shaolin)" do
    cache.write("h", { a: 1, b: [1, 2] })
    expect(cache.read("h")).to eq(a: 1, b: [1, 2])
    cache.write("n", 42)
    expect(cache.read("n")).to eq(42)
  end

  it "returns nil and false for a missing key" do
    expect(cache.read("nope")).to be_nil
    expect(cache.exist?("nope")).to be(false)
  end

  it "fetch computes once, then hits the cache" do
    calls = 0
    expect(cache.fetch("k") { calls += 1; "v" }).to eq("v")
    expect(cache.fetch("k") { calls += 1; "other" }).to eq("v")
    expect(calls).to eq(1)
  end

  it "sets a server-side TTL with write(ttl:)" do
    cache.write("temp", "v", ttl: 50)
    ttl = pool.with { |r| r.ttl("t:cache:temp") }
    expect(ttl).to be_between(1, 50)
  end

  it "clears only its own namespace" do
    cache.write("a", 1)
    pool.with { |r| r.set("other:key", "keep") }
    cache.clear
    expect(cache.exist?("a")).to be(false)
    expect(pool.with { |r| r.get("other:key") }).to eq("keep")
  end
end

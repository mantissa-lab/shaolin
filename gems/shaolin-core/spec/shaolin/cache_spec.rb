require "shaolin/core"

RSpec.describe Shaolin::Cache::Memory do
  subject(:cache) { described_class.new }

  it "writes and reads a value" do
    cache.write("k", 42)
    expect(cache.read("k")).to eq(42)
  end

  it "returns nil for a missing key" do
    expect(cache.read("missing")).to be_nil
    expect(cache.exist?("missing")).to be(false)
  end

  it "fetch computes and stores on a miss, and returns the cached value on a hit" do
    calls = 0
    first  = cache.fetch("k") { calls += 1; "computed" }
    second = cache.fetch("k") { calls += 1; "again" }

    expect(first).to eq("computed")
    expect(second).to eq("computed")
    expect(calls).to eq(1)
  end

  it "expires entries past their ttl" do
    now = Time.now
    cache.write("k", "v", ttl: 60)
    expect(cache.read("k", now: now)).to eq("v")
    expect(cache.read("k", now: now + 61)).to be_nil
  end

  it "deletes and clears" do
    cache.write("a", 1)
    cache.write("b", 2)
    cache.delete("a")
    expect(cache.exist?("a")).to be(false)
    cache.clear
    expect(cache.exist?("b")).to be(false)
  end

  it "is a Shaolin::Cache (the swappable port)" do
    expect(cache).to be_a(Shaolin::Cache)
  end
end

require "spec_helper"

RSpec.describe "Shaolin::Redis.register_provider!" do
  before do
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
  end

  it "registers the cache, store, and broker into the kernel" do
    Shaolin::Redis.register_provider!(url: REDIS_TEST_URL, namespace: "t")
    Shaolin::Provider.start_all

    expect(Shaolin::Kernel["redis.cache"]).to be_a(Shaolin::Redis::Cache)
    expect(Shaolin::Kernel["redis.store"]).to be_a(Shaolin::Redis::Store)
    expect(Shaolin::Kernel["redis.publisher"]).to be_a(Shaolin::Redis::StreamPublisher)
    # the generic cache port resolves to the same Redis cache
    expect(Shaolin::Kernel["cache.store"]).to be(Shaolin::Kernel["redis.cache"])
  end

  it "wires a working cache through the kernel" do
    Shaolin::Redis.register_provider!(url: REDIS_TEST_URL, namespace: "t")
    Shaolin::Provider.start_all

    cache = Shaolin::Kernel["cache.store"]
    cache.write("hello", "world")
    expect(cache.read("hello")).to eq("world")
  end
end

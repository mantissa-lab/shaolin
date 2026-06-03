require "shaolin/core"

RSpec.describe Shaolin::Health do
  before { described_class.reset! }
  after  { described_class.reset! }

  it "is ready when every registered check passes" do
    described_class.register("db") { true }
    described_class.register("cache") { true }
    ok, detail = described_class.status
    expect(ok).to be(true)
    expect(detail).to eq("db" => true, "cache" => true)
  end

  it "is not ready when any check fails or raises" do
    described_class.register("db") { true }
    described_class.register("broker") { false }
    described_class.register("cache") { raise "down" }
    ok, detail = described_class.status
    expect(ok).to be(false)
    expect(detail).to eq("db" => true, "broker" => false, "cache" => false)
  end

  it "is ready with no checks registered" do
    expect(described_class.status).to eq([true, {}])
  end
end

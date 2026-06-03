require "shaolin/core"

RSpec.describe Shaolin::Tenant do
  after { described_class.current = nil }

  it "defaults to nil" do
    expect(described_class.current).to be_nil
  end

  it "sets and reads the current tenant" do
    described_class.current = "acme"
    expect(described_class.current).to eq("acme")
  end

  it "scopes the tenant to a block and restores the previous value" do
    described_class.current = "outer"
    inside = nil
    described_class.with("inner") { inside = described_class.current }
    expect(inside).to eq("inner")
    expect(described_class.current).to eq("outer")
  end

  it "restores even when the block raises" do
    described_class.with("t") { raise "boom" } rescue nil
    expect(described_class.current).to be_nil
  end
end

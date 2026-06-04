require "shaolin/core"

RSpec.describe Shaolin::Context do
  after { described_class.clear }

  it "stores and reads request-scoped values" do
    described_class[:project_id] = "p-1"
    expect(described_class[:project_id]).to eq("p-1")
    expect(described_class.to_h).to eq(project_id: "p-1")
  end

  it "clears all values" do
    described_class[:a] = 1
    described_class.clear
    expect(described_class.to_h).to eq({})
  end

  it "scopes values to a block and restores the previous bag" do
    described_class[:a] = 1
    inside = nil
    described_class.with(b: 2) { inside = described_class.to_h }
    expect(inside).to eq(a: 1, b: 2)
    expect(described_class.to_h).to eq(a: 1)
  end

  it "is merged into log records" do
    Shaolin::Log.reset!
    captured = []
    Shaolin::Log.sinks = [->(r) { captured << r }]
    described_class[:project_id] = "p-9"
    Shaolin::Log.info("hit")
    expect(captured.first[:project_id]).to eq("p-9")
  ensure
    Shaolin::Log.reset!
  end
end

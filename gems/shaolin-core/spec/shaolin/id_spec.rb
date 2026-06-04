require "shaolin/core"

RSpec.describe Shaolin::Id do
  describe ".deterministic" do
    it "is stable for the same parts (idempotent ingest key)" do
      a = described_class.deterministic("orders", "ext-123")
      b = described_class.deterministic("orders", "ext-123")
      expect(a).to eq(b)
    end

    it "differs for different parts" do
      expect(described_class.deterministic("a")).not_to eq(described_class.deterministic("b"))
    end

    it "produces a v5-shaped UUID" do
      expect(described_class.deterministic("x")).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    it "namespacing changes the result" do
      expect(described_class.deterministic("x", namespace: "a"))
        .not_to eq(described_class.deterministic("x", namespace: "b"))
    end

    it "requires at least one part" do
      expect { described_class.deterministic }.to raise_error(ArgumentError)
    end
  end

  describe ".generate" do
    it "returns a random UUID" do
      expect(described_class.generate).to match(/\A[0-9a-f-]{36}\z/)
      expect(described_class.generate).not_to eq(described_class.generate)
    end
  end
end

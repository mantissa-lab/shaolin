require "shaolin/core"

RSpec.describe Shaolin::Keys do
  describe ".deep_symbolize" do
    it "symbolizes string keys recursively (hashes + arrays)" do
      input = { "id" => "1", "meta" => { "tags" => [{ "k" => "v" }] } }
      expect(described_class.deep_symbolize(input)).to eq(id: "1", meta: { tags: [{ k: "v" }] })
    end

    it "leaves non-hash/array values and symbol keys alone" do
      expect(described_class.deep_symbolize(id: 1, name: "x")).to eq(id: 1, name: "x")
      expect(described_class.deep_symbolize("scalar")).to eq("scalar")
    end
  end
end

require "shaolin/core"

RSpec.describe Shaolin::Inflector do
  it "is acronym-aware (so generator names and the autoloader agree)" do
    expect(described_class.camelize("url_maps")).to eq("URLMaps")
    expect(described_class.camelize("api_keys")).to eq("APIKeys")
    expect(described_class.camelize("user_profiles")).to eq("UserProfiles")
  end

  it "is the same instance the container builder uses (single source of truth)" do
    expect(Shaolin::ContainerBuilder.inflector).to be(described_class.instance)
  end
end

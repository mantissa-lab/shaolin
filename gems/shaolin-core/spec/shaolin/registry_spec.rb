require "shaolin/core"

RSpec.describe Shaolin::Registry do
  before { Shaolin::Registry.reset! }

  it "registers and finds modules by name" do
    defn = Shaolin.module("users") { exports "user_service" }
    expect(Shaolin::Registry.find("users")).to be(defn)
    expect(Shaolin::Registry.names).to eq(["users"])
  end

  it "rejects duplicate module names" do
    Shaolin.module("users") {}
    expect { Shaolin.module("users") {} }.to raise_error(Shaolin::ManifestError, /users/)
  end
end

require "shaolin/errors"

RSpec.describe "Shaolin errors" do
  it "ManifestError carries the offending module name" do
    err = Shaolin::ManifestError.new("bad", module_name: "users")
    expect(err.module_name).to eq("users")
    expect(err.message).to include("users")
  end

  it "IsolationError names consumer, key, and owner" do
    err = Shaolin::IsolationError.new(consumer: "users", key: "billing.secret", owner: "billing")
    expect(err.message).to include("users").and include("billing.secret").and include("billing")
  end

  it "exposes a machine-readable contract" do
    err = Shaolin::ManifestError.new("bad", module_name: "users")
    expect(err.to_contract).to include(code: "ManifestError")
  end
end

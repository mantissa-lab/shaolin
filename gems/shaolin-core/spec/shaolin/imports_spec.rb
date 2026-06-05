require "shaolin/core"

RSpec.describe Shaolin::Imports do
  # a component living in module "billing"
  module Billing
    class Charger
      include Shaolin::Imports
    end
  end

  before do
    Shaolin::Registry.reset!
    Shaolin::Kernel.reset!
    Shaolin.module("billing") { imports "accounts.balance_reader" }
    fake_container = { "accounts.balance_reader" => :the_reader }
    Shaolin::Kernel.register("kernel.containers", { "billing" => fake_container })
  end

  after { Shaolin::Registry.reset! }

  it "resolves a declared import via the module's own container" do
    expect(Billing::Charger.new.import("accounts.balance_reader")).to eq(:the_reader)
  end

  it "raises a clear error for a key the manifest does not import" do
    expect { Billing::Charger.new.import("accounts.secret") }
      .to raise_error(Shaolin::Error, /does not import "accounts.secret"/)
  end
end

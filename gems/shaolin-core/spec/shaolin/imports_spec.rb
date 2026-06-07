require "shaolin/core"

module Accounts
  module Commands
    class ChargeCard
      attr_reader :amount
      def initialize(amount:) = (@amount = amount)
    end
  end
end

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
    Shaolin.module("billing") do
      imports "accounts.balance_reader"
      imports commands: ["accounts.charge_card"]
    end
    Shaolin::Kernel.register("kernel.containers", { "billing" => { "accounts.balance_reader" => :the_reader } })
  end

  after { Shaolin::Registry.reset! }

  it "resolves a declared import via the module's own container" do
    expect(Billing::Charger.new.import("accounts.balance_reader")).to eq(:the_reader)
  end

  it "raises a clear error for a key the manifest does not import" do
    expect { Billing::Charger.new.import("accounts.secret") }
      .to raise_error(Shaolin::Error, /does not import "accounts.secret"/)
  end

  it "#29 dispatch sends a declared cross-module command on the command bus" do
    seen = []
    Shaolin::Kernel.register("cqrs.command_bus", Object.new.tap { |b| b.define_singleton_method(:call) { |cmd| seen << cmd } })

    Billing::Charger.new.dispatch("accounts.charge_card", amount: 100)

    expect(seen.size).to eq(1)
    expect(seen.first).to be_a(Accounts::Commands::ChargeCard)
    expect(seen.first.amount).to eq(100)
  end

  it "#29 dispatch raises for a command the manifest does not import" do
    expect { Billing::Charger.new.dispatch("accounts.refund", amount: 1) }
      .to raise_error(Shaolin::Error, /does not import command "accounts.refund"/)
  end
end

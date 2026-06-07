require "shaolin/core"

RSpec.describe Shaolin::Topic do
  describe ".event_class_name" do
    it "maps a dotted topic to its namespaced event class (generator inflection)" do
      expect(described_class.event_class_name("conversions.conversion_recorded"))
        .to eq("Conversions::Events::ConversionRecorded")
    end

    it "keeps multi-word event segments together" do
      expect(described_class.event_class_name("orders.order_line_added"))
        .to eq("Orders::Events::OrderLineAdded")
    end

    it "rejects a topic without a module.event shape" do
      expect { described_class.event_class_name("nodot") }.to raise_error(ArgumentError)
    end
  end

  describe ".command_class_name" do
    it "maps a dotted command key to its namespaced command class" do
      expect(described_class.command_class_name("call.create_call")).to eq("Call::Commands::CreateCall")
      expect(described_class.command_class_name("billing.charge_card")).to eq("Billing::Commands::ChargeCard")
    end

    it "rejects a key without a module.command shape" do
      expect { described_class.command_class_name("nodot") }.to raise_error(ArgumentError)
    end
  end

  describe ".module_name" do
    it "returns the owning module segment" do
      expect(described_class.module_name("conversions.conversion_recorded")).to eq("conversions")
    end
  end
end

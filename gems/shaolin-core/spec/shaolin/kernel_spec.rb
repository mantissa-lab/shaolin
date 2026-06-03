require "shaolin/core"

RSpec.describe Shaolin::Kernel do
  before { Shaolin::Kernel.reset! }

  it "registers and resolves an eager value" do
    Shaolin::Kernel.register("cqrs.command_bus", :the_bus)
    expect(Shaolin::Kernel["cqrs.command_bus"]).to eq(:the_bus)
    expect(Shaolin::Kernel.key?("cqrs.command_bus")).to be(true)
  end

  it "resolves a lazy block on demand" do
    Shaolin::Kernel.register("svc") { :built }
    expect(Shaolin::Kernel["svc"]).to eq(:built)
  end

  describe "ModuleContainer fallback" do
    let(:fake_container) { Class.new { def key?(_k) = false; def [](_k) = nil }.new }
    let(:mc) do
      Shaolin::ModuleContainer.new(
        definition: Shaolin::ModuleDefinition.new("users"),
        container: fake_container
      )
    end

    it "falls back to the kernel for infra components" do
      Shaolin::Kernel.register("cqrs.command_bus", :bus)
      expect(mc["cqrs.command_bus"]).to eq(:bus)
      expect(mc.key?("cqrs.command_bus")).to be(true)
    end

    it "still raises IsolationError for unknown keys" do
      expect { mc["nope"] }.to raise_error(Shaolin::IsolationError, /nope/)
    end
  end
end

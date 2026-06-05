require "shaolin/jobs"

# Reactors get the same cross-module `import(...)` as controllers/handlers, so a
# reactor block resolves another module's component the lint-checked way instead
# of hand-navigating `Kernel["kernel.containers"][...]`.
RSpec.describe "Shaolin::Jobs::Reactor#import" do
  module Conversions
    module Reactors
      class MetaBridgeReactor < Shaolin::Jobs::Reactor
        on("ads.click_recorded") { |event| $imported = import("ads.uploader").push(event) }
      end
    end
  end

  before do
    Shaolin::Registry.reset!
    Shaolin::Kernel.reset!
    Shaolin.module("conversions") do
      imports "ads.uploader"
      imports events: ["ads.click_recorded"]
    end
    uploader = Class.new { def push(e) = "uploaded:#{e}" }.new
    Shaolin::Kernel.register("kernel.containers", { "conversions" => { "ads.uploader" => uploader } })
    $imported = nil
  end

  after { Shaolin::Registry.reset! }

  it "resolves a declared import from inside the reactor block" do
    handler = Conversions::Reactors::MetaBridgeReactor.topic_handlers.each_value.first
    Conversions::Reactors::MetaBridgeReactor.new.instance_exec("clk1", &handler)
    expect($imported).to eq("uploaded:clk1")
  end

  it "raises a clear error for an undeclared import key" do
    expect { Conversions::Reactors::MetaBridgeReactor.new.import("ads.secret") }
      .to raise_error(Shaolin::Error, /does not import "ads.secret"/)
  end
end

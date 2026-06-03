require "shaolin/core"

RSpec.describe Shaolin::Provider do
  before { Shaolin::Provider.reset! }

  it "starts providers in dependency order" do
    order = []
    Shaolin.register_provider(:cqrs, after: [:active_record]) { start { order << :cqrs } }
    Shaolin.register_provider(:active_record) { start { order << :active_record } }

    Shaolin::Provider.start_all
    expect(order).to eq(%i[active_record cqrs])
  end

  it "runs stop hooks in reverse dependency order" do
    order = []
    Shaolin.register_provider(:a) { stop { order << :a } }
    Shaolin.register_provider(:b, after: [:a]) { stop { order << :b } }

    Shaolin::Provider.stop_all
    expect(order).to eq(%i[b a])
  end

  it "raises BootError on an unknown dependency" do
    Shaolin.register_provider(:x, after: [:missing]) { start {} }
    expect { Shaolin::Provider.start_all }.to raise_error(Shaolin::BootError, /missing/)
  end

  it "raises BootError on a dependency cycle" do
    Shaolin.register_provider(:a, after: [:b]) { start {} }
    Shaolin.register_provider(:b, after: [:a]) { start {} }
    expect { Shaolin::Provider.start_all }.to raise_error(Shaolin::BootError, /cycle/)
  end
end

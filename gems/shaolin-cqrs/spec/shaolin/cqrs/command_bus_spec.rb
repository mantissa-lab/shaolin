require "shaolin/cqrs"

class Ping; end

RSpec.describe Shaolin::CQRS::CommandBus do
  it "routes a command to its lambda handler" do
    seen = []
    bus = described_class.new
    bus.register(Ping, ->(cmd) { seen << cmd })

    command = Ping.new
    bus.call(command)
    expect(seen).to eq([command])
  end

  it "supports object handlers responding to #call" do
    seen = []
    handler = Class.new do
      define_method(:initialize) { |sink| @sink = sink }
      define_method(:call) { |_cmd| @sink << :handled }
    end.new(seen)

    bus = described_class.new
    bus.register(Ping, handler)
    bus.call(Ping.new)
    expect(seen).to eq([:handled])
  end

  it "raises UnregisteredCommand for an unknown command" do
    expect { described_class.new.call(Ping.new) }
      .to raise_error(Shaolin::CQRS::UnregisteredCommand, /Ping/)
  end
end

require "shaolin/cqrs"

class FindThing
  attr_reader :id
  def initialize(id) = (@id = id)
end

RSpec.describe Shaolin::CQRS::QueryBus do
  it "routes a query to its handler and returns the result" do
    bus = described_class.new
    bus.register(FindThing, ->(q) { "thing-#{q.id}" })
    expect(bus.call(FindThing.new(7))).to eq("thing-7")
  end

  it "raises UnregisteredQuery for an unknown query" do
    expect { described_class.new.call(FindThing.new(1)) }
      .to raise_error(Shaolin::CQRS::UnregisteredQuery, /FindThing/)
  end
end

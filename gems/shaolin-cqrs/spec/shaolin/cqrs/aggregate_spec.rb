require "shaolin/cqrs"

class Bumped < RubyEventStore::Event; end

class Counter
  include Shaolin::CQRS::Aggregate

  def initialize(id)
    super(id)
    @count = 0
  end

  attr_reader :count

  def bump = apply(Bumped.new(data: {}))

  on Bumped do |_event|
    @count += 1
  end
end

RSpec.describe Shaolin::CQRS::Aggregate do
  it "stores the aggregate id" do
    expect(Counter.new("c1").id).to eq("c1")
  end

  it "applies events and mutates state via the on DSL" do
    counter = Counter.new("c1")
    counter.bump
    counter.bump
    expect(counter.count).to eq(2)
    expect(counter.unpublished_events.to_a.size).to eq(2)
  end
end

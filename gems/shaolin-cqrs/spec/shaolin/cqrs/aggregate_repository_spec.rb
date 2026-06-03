require "shaolin/cqrs"

class Added < RubyEventStore::Event; end

class Accumulator
  include Shaolin::CQRS::Aggregate

  def initialize(id)
    super(id)
    @total = 0
  end

  attr_reader :total

  def add(value) = apply(Added.new(data: { value: value }))

  on Added do |event|
    @total += event.data[:value]
  end
end

RSpec.describe Shaolin::CQRS::AggregateRepository do
  subject(:repository) { described_class.new(Shaolin::CQRS::EventStore.in_memory) }

  it "persists via unit_of_work and rebuilds via load (event sourcing)" do
    repository.unit_of_work(Accumulator.new("a1")) do |acc|
      acc.add(3)
      acc.add(4)
    end

    expect(repository.load(Accumulator, "a1").total).to eq(7)
  end
end

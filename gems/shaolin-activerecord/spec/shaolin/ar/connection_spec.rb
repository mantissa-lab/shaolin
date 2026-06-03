require "shaolin/activerecord"
require "support/pg"

RSpec.describe Shaolin::AR::Connection do
  it "establishes a working connection from a hash config" do
    described_class.establish!(PgTest::CONFIG)
    expect(described_class.connected?).to be(true)
  end

  it "sets and reads the concurrency isolation level" do
    described_class.isolation_level = :fiber
    expect(described_class.isolation_level).to eq(:fiber)
  ensure
    described_class.isolation_level = :thread
  end
end

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

  it "reading is a no-op passthrough when no replica is configured" do
    described_class.establish!(PgTest::CONFIG) # no replica
    expect(described_class.reading { :ran }).to eq(:ran)
    expect(described_class.reading { ActiveRecord::Base.connection.select_value("SELECT 7") }).to eq(7)
  end

  it "#27 routes reads to the replica via the reading role; writes stay on primary" do
    # same DB stands in for the replica — exercises the role-routing wiring
    described_class.establish!(PgTest::CONFIG, replica: PgTest::CONFIG)
    conn = ActiveRecord::Base.connection
    conn.execute("DROP TABLE IF EXISTS rr_probe")
    conn.execute("CREATE TABLE rr_probe (id int)")

    # write on the primary (writing role / default), inside a transaction
    ActiveRecord::Base.transaction { ActiveRecord::Base.connection.execute("INSERT INTO rr_probe VALUES (42)") }

    # read through the reading role
    read = Shaolin::AR.reading { ActiveRecord::Base.connection.select_value("SELECT id FROM rr_probe") }
    expect(read).to eq(42)
  ensure
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS rr_probe") rescue nil
    ActiveRecord::Base.establish_connection(PgTest::CONFIG) # restore single-DB for other specs
  end
end

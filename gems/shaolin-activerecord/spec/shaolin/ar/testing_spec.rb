require "shaolin/activerecord"
require "support/pg"

RSpec.describe Shaolin::Testing do
  before do
    PgTest.reset_schema!
    conn = ActiveRecord::Base.connection
    conn.create_table(:widgets_read, id: :string) { |t| t.string :name } unless conn.table_exists?("widgets_read")
  end

  it "truncates every app table (read models, event store, outbox)" do
    Shaolin::AR::EventStoreSchema.create!
    conn = ActiveRecord::Base.connection
    conn.execute("INSERT INTO widgets_read (id, name) VALUES ('w1', 'A')")

    expect(conn.select_value("SELECT count(*) FROM widgets_read").to_i).to eq(1)
    described_class.clean!
    expect(conn.select_value("SELECT count(*) FROM widgets_read").to_i).to eq(0)
    expect(conn.table_exists?("widgets_read")).to be(true) # truncated, not dropped
  end

  it "preserves AR bookkeeping tables" do
    expect(described_class::PRESERVE).to include("schema_migrations")
  end
end

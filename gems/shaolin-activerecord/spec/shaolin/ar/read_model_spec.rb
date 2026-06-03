require "shaolin/activerecord"
require "support/pg"

RSpec.describe Shaolin::AR::ReadModel do
  before do
    PgTest.reset_schema!
    ActiveRecord::Base.connection.create_table(:users_read, id: false) do |t|
      t.string :id, null: false
      t.string :email
    end
    ActiveRecord::Base.connection.execute("ALTER TABLE users_read ADD PRIMARY KEY (id)")
    stub_const("UsersRead", Class.new(described_class) { self.table_name = "users_read" })
  end

  it "inserts on first projection" do
    UsersRead.project(id: "u1") { |r| r.email = "a@b.c" }
    expect(UsersRead.find("u1").email).to eq("a@b.c")
  end

  it "is idempotent: re-projecting the same id updates one row" do
    UsersRead.project(id: "u1") { |r| r.email = "a@b.c" }
    UsersRead.project(id: "u1") { |r| r.email = "new@b.c" }
    expect(UsersRead.count).to eq(1)
    expect(UsersRead.find("u1").email).to eq("new@b.c")
  end
end

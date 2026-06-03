require "shaolin/cqrs"

module Users
  class User; end
end

RSpec.describe "Shaolin::CQRS.stream_name" do
  it "builds <AggregateClass>$<id>" do
    expect(Shaolin::CQRS.stream_name(Users::User, "u1")).to eq("Users::User$u1")
  end

  it "coerces the id to string" do
    expect(Shaolin::CQRS.stream_name(Users::User, 42)).to eq("Users::User$42")
  end
end

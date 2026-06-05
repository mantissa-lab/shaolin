require "shaolin/dto"

class RegisterUserDTO < Shaolin::DTO
  json do
    required(:email).filled(:string)
    required(:name).filled(:string)
    optional(:age).maybe(:integer)
  end

  rule(:email) do
    key.failure("has invalid format") unless value.include?("@")
  end
end

RSpec.describe Shaolin::DTO do
  it "returns success with the coerced attributes" do
    result = RegisterUserDTO.validate("email" => "a@b.c", "name" => "Jane")
    expect(result.success?).to be(true)
    expect(result.to_h).to eq(email: "a@b.c", name: "Jane")
  end

  it "returns a per-field errors hash on failure" do
    result = RegisterUserDTO.validate("email" => "bad", "name" => "")
    expect(result.failure?).to be(true)
    expect(result.errors.keys).to include(:email, :name)
  end
end

class PriceDTO < Shaolin::DTO
  json do
    required(:name).filled(:string)
    required(:amount).filled(:float)
  end
end

RSpec.describe "DTO numeric coercion" do
  it "coerces an integer to a float for a :float field (JSON 5 -> 5.0)" do
    result = PriceDTO.validate(name: "x", amount: 5)
    expect(result.success?).to be(true)
    expect(result.to_h).to eq(name: "x", amount: 5.0)
  end

  it "still rejects a non-numeric for :float, and keeps :string strict" do
    expect(PriceDTO.validate(name: "x", amount: "nope").failure?).to be(true)
    expect(PriceDTO.validate(name: 5, amount: 1.0).failure?).to be(true) # :string not coerced
  end
end

class Money < Shaolin::ValueObject
  attribute :amount, Shaolin::Types::Integer
  attribute :currency, Shaolin::Types::String
end

RSpec.describe Shaolin::ValueObject do
  it "builds a typed value object" do
    money = Money.new(amount: 100, currency: "USD")
    expect(money.amount).to eq(100)
    expect(money.currency).to eq("USD")
  end

  it "rejects a wrong type" do
    expect { Money.new(amount: "nope", currency: "USD") }.to raise_error(Dry::Struct::Error)
  end
end

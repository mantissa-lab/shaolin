require "shaolin/dto"

module Orders
  module Commands
    class PlaceOrder < Shaolin::ValueObject
      attribute :id, Shaolin::Types::String
      attribute :total, Shaolin::Types::Integer
    end
  end
end

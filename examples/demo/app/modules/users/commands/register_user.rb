require "shaolin/dto"

module Users
  module Commands
    # Trusted, typed intent (built from a validated DTO).
    class RegisterUser < Shaolin::ValueObject
      attribute :id, Shaolin::Types::String
      attribute :name, Shaolin::Types::String
      attribute :email, Shaolin::Types::String
    end
  end
end

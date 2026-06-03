require "shaolin/dto"

module Users
  module DTO
    class RegisterUserDTO < Shaolin::DTO
      json do
        required(:name).filled(:string)
        required(:email).filled(:string)
      end

      rule(:email) do
        key.failure("has invalid format") unless value.to_s.include?("@")
      end
    end
  end
end

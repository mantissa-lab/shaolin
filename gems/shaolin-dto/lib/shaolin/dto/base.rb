require "dry/validation"

module Shaolin
  # Boundary validation contract. Subclass and declare a `json`/`params`/`schema`
  # block plus optional `rule`s; `.validate(input)` returns a stable
  # `Shaolin::DTO::Result` so transports never couple to dry-validation internals.
  #
  #   class RegisterUserDTO < Shaolin::DTO
  #     json { required(:email).filled(:string) }
  #     rule(:email) { key.failure("invalid") unless value.include?("@") }
  #   end
  class DTO < Dry::Validation::Contract
    def self.validate(input)
      Result.new(new.call(input))
    end

    # Stable wrapper over a dry-validation result.
    class Result
      def initialize(validation_result)
        @result = validation_result
      end

      def success? = @result.success?
      def failure? = @result.failure?
      def to_h     = @result.to_h
      def errors   = @result.errors.to_h
    end
  end
end

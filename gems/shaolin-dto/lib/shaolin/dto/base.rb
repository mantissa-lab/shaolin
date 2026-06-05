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
    # Coerce JSON numbers leniently: an integer is accepted where a :float is
    # declared (JSON `5` for a float field becomes 5.0 instead of failing
    # "must be a float"). Inherited by every DTO; :string etc. stay strict.
    config.types.register("json.float", Dry::Types["coercible.float"])

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

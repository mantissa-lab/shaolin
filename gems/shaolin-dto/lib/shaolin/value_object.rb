require "dry/struct"
require_relative "types"

module Shaolin
  # Immutable, typed value-object base for commands and queries (built on
  # dry-struct). The validated DTO hash is used to construct one — DTO is
  # untrusted input; a ValueObject is trusted, typed intent.
  class ValueObject < Dry::Struct
    transform_keys(&:to_sym)
  end
end

require "dry/types"

module Shaolin
  # Shared dry-types module for typed value objects (commands/queries) and DTOs.
  module Types
    include Dry.Types()
  end
end

require "ruby_event_store"

require_relative "cqrs/version"
require_relative "cqrs/stream_name"
require_relative "cqrs/aggregate"
require_relative "cqrs/command_bus"
require_relative "cqrs/query_bus"
require_relative "cqrs/event_store"
require_relative "cqrs/aggregate_repository"
require_relative "cqrs/command_handler"
require_relative "cqrs/query_handler"
require_relative "cqrs/projection"

module Shaolin
  module CQRS
    # building blocks required above; provider wiring added in a later task
  end
end

require_relative "cqrs/provider"

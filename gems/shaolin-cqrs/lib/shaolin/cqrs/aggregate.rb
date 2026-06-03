require "aggregate_root"

module Shaolin
  module CQRS
    # Base for event-sourced aggregates. Including it brings in aggregate_root's
    # `apply` and `on` DSL and adds an `id` (the aggregate identity used to
    # derive its event stream). Subclasses call `super(id)` from `initialize`.
    module Aggregate
      def self.included(base)
        base.include(AggregateRoot)
      end

      attr_reader :id

      def initialize(id)
        @id = id
      end
    end
  end
end

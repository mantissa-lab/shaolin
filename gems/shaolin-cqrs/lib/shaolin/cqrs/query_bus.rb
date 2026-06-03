require "shaolin/core"

module Shaolin
  module CQRS
    # Raised when a query is dispatched with no registered handler.
    class UnregisteredQuery < Shaolin::Error; end

    # Symmetric to CommandBus for the read side. ruby_event_store has no query
    # bus, so this is a thin shaolin construct: one handler per query class,
    # returning the handler's result.
    class QueryBus
      def initialize = (@handlers = {})

      def register(query_class, handler)
        @handlers[query_class] = handler
        self
      end

      def call(query)
        handler = @handlers[query.class]
        raise UnregisteredQuery, "no handler registered for #{query.class}" unless handler

        Shaolin::Log.info("query", query: query.class.name) if Shaolin::Log.everything?
        handler.call(query)
      end

      def registered?(query_class) = @handlers.key?(query_class)
    end
  end
end

require "shaolin/core"

module Shaolin
  module CQRS
    # Base for query handlers (read side). Declare the query it handles with
    # `handles`; the :cqrs provider auto-registers it on the query bus at boot.
    # Query handlers read ActiveRecord read models (projections) and return data.
    #
    #   class FindUserHandler < Shaolin::CQRS::QueryHandler
    #     handles Queries::FindUser
    #     def call(query) = ReadModels::UserRecord.find_by(id: query.id)
    #   end
    class QueryHandler
      def self.handles(query_class) = (@handled_query = query_class)
      def self.handled_query = @handled_query
    end
  end
end

require "shaolin/cqrs"
require "dry/monads"
require_relative "../order"
require_relative "../commands/place_order"

module Orders
  module CommandHandlers
    class PlaceOrderHandler < Shaolin::CQRS::CommandHandler
      include Dry::Monads[:result]

      handles Commands::PlaceOrder

      def call(cmd)
        aggregate_repository.unit_of_work(Order.new(cmd.id)) { |o| o.place(total: cmd.total) }
        Success(cmd.id)
      end
    end
  end
end

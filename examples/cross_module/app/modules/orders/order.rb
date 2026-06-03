require "shaolin/cqrs"
require_relative "events/order_placed"

module Orders
  class Order
    include Shaolin::CQRS::Aggregate

    def place(total:)
      apply(Events::OrderPlaced.new(data: { id: id, total: total }))
    end

    on(Events::OrderPlaced) { |_event| }
  end
end

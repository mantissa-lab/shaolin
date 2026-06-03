require "shaolin/jobs"
require "shaolin/messaging"

module Notifications
  module Reactors
    # Reacts to ANOTHER module's event (orders) by TOPIC STRING — lint-clean, no
    # reference to Orders::Events::*. The :jobs provider resolves the topic to its
    # event class at wire time. Runs in `shaolin worker` via the transactional
    # outbox (at-least-once → idempotent).
    class OrderNotifier < Shaolin::Jobs::Reactor
      on("orders.order_placed") do |event|
        Shaolin::Kernel["messaging.publisher"].publish(
          Shaolin::Messaging::IntegrationEvent.new(
            event_type: "notifications.order_acknowledged",
            payload: { order_id: event.data[:id] }
          )
        )
      end
    end
  end
end

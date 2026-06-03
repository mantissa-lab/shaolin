require_relative "config/boot"
require "shaolin/jobs"

CrossModuleExample.boot!

command_bus = Shaolin::Kernel["cqrs.command_bus"]
outbox      = Shaolin::Kernel["jobs.outbox"]
publisher   = Shaolin::Kernel["messaging.publisher"]
Shaolin::Jobs::OutboxJob.delete_all

puts "== module A: place an order (command -> OrderPlaced event) =="
command_bus.call(Orders::Commands::PlaceOrder.new(id: "o-1", total: 4200))

puts "\n== module B reacted via topic: an outbox job exists, in the same transaction =="
job = Shaolin::Jobs::OutboxJob.where(status: "pending").first
raise "expected a pending outbox job for B" unless job
puts "  reactor:    #{job.reactor}"
puts "  event_type: #{job.event_type}"
raise unless job.reactor == "Notifications::Reactors::OrderNotifier"
raise unless job.event_type == "Orders::Events::OrderPlaced"
raise "reactor must not have run yet" unless publisher.published.empty?

puts "\n== run the worker once =="
Shaolin::Jobs::Worker.new(event_store: Shaolin::Kernel["cqrs.event_store"]).run_once

puts "\n== module B's side effect ran with the reconstructed A event =="
published = publisher.published
raise "expected one integration event" unless published.size == 1
ie = published.first
puts "  published:  #{ie.event_type} #{ie.payload.inspect}"
raise unless ie.event_type == "notifications.order_acknowledged"
raise unless ie.payload == { order_id: "o-1" }
raise unless Shaolin::Jobs::OutboxJob.where(status: "done").count == 1

puts "\n✅ cross-module reactor OK — orders.order_placed (A) -> outbox -> worker -> notifications (B), isolation-clean"

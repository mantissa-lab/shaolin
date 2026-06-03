Shaolin.module "orders" do
  commands_handled "Orders::Commands::PlaceOrder"
  events_published "orders.order_placed"
end

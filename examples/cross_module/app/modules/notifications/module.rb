Shaolin.module "notifications" do
  # Declares the cross-module event this module consumes — by topic string, the
  # same dotted contract name `orders` exposes in its `events_published`. No
  # reference to Orders' classes, so isolation (lint) stays clean.
  imports events: ["orders.order_placed"]
end

# examples/cross_module — a reactor reacting to ANOTHER module's event (by topic)

In a modular monolith, module **B** often needs to react to a domain event published by module **A** —
without breaking isolation (no reference to A's event class, so `shaolin lint` stays clean).

Here `orders` publishes `orders.order_placed`; `notifications` reacts to it **by topic string**:

```ruby
# notifications/module.rb — declare the cross-module event you consume
Shaolin.module "notifications" do
  imports events: ["orders.order_placed"]
end

# notifications/reactors/order_notifier.rb — subscribe by the dotted topic, not a class
class OrderNotifier < Shaolin::Jobs::Reactor
  on("orders.order_placed") { |event| ... }   # lint-clean: a string, not Orders::Events::*
end
```

The `:jobs` provider resolves the topic to its event class at wire time
(`orders.order_placed` → `Orders::Events::OrderPlaced`) and subscribes the outbox enqueue to it. So the
reactor's job is written **in the same transaction** as A's event (transactional outbox), and runs in
`shaolin worker` with the reconstructed A event — same dispatch as an own-module `on(EventClass)`.

## Run it

```bash
createdb -h /tmp -p 5433 -U postgres shaolin_cross_example
ruby examples/cross_module/verify.rb
```

`shaolin lint` → clean. `shaolin graph` shows the edge `notifications -> orders`. `shaolin describe
--json` lists the reactor's `topics` and the module's `events_subscribed`.

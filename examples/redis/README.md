# examples/redis — Redis in three roles

A focused script exercising `shaolin-redis` end-to-end: **cache** (cache-aside + TTL), **store**
(Redis as a database — key/value, hashes, counters), and **broker** (Streams + consumer group with
acks).

## Run it

```bash
redis-server --port 6399 --daemonize yes --save ""     # one ephemeral instance
REDIS_URL=redis://127.0.0.1:6399/0 ruby examples/redis/verify.rb
```

Expected tail:

```
✅ shaolin Redis end-to-end OK — cache, store, and broker all working
```

## Swapping the broker

`StreamPublisher` implements the same `Shaolin::Messaging::Publisher` port as `Shaolin::RabbitMQ::Publisher`
and the in-memory publisher — so a reactor's side effect (`publisher.publish(...)`) works over Redis
Streams, RabbitMQ, or in-process without any change to the reactor. See `examples/reactor`.

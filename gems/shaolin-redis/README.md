# shaolin-redis

Redis integration for [shaolin](https://github.com/shaolin-rb/shaolin), in three roles, all on
`redis-rb` (pure Ruby) with a shared `connection_pool`:

## 1. Cache — `Shaolin::Redis::Cache`

Implements the `Shaolin::Cache` port, so it is a drop-in swap for the in-memory
`Shaolin::Cache::Memory`. Cache-aside with shared, server-side TTL:

```ruby
cache = Shaolin::Kernel["cache.store"]            # or Shaolin::Redis::Cache.new(pool:)
cache.fetch("user:#{id}:profile", ttl: 300) { load_profile(id) }
cache.write("k", { any: "json" }, ttl: 60)
cache.read("k")   # => {any: "world"} (symbol keys, like the rest of shaolin)
cache.delete("k"); cache.clear
```

## 2. Store — `Shaolin::Redis::Store` (Redis as a database)

Namespaced key-value + hash store with JSON values. The source of truth (no implicit TTL) — use it
for read models, sessions, feature flags, counters, or LLM state (conversation context, rate-limit
windows). Distinct from the cache, which is disposable.

```ruby
store = Shaolin::Kernel["redis.store"]
store.set("user:1", { id: "1", name: "Neo" }); store.get("user:1")  # => {id: "1", name: "Neo"}
store.increment("signups:2026-06")                                  # native INCR
store.hset("session:abc", "user_id", "1"); store.hgetall("session:abc")
store.keys("user:*")
```

## 3. Broker

**Streams (reliable, at-least-once)** — `StreamPublisher` implements the `Shaolin::Messaging::Publisher`
port (drop-in for RabbitMQ/in-memory); `StreamConsumer` uses consumer groups so multiple workers share
the load, ack what they process, and reclaim a crashed worker's un-acked entries (`XAUTOCLAIM`).
Reactors publish through the outbox, so delivery stays reliable across crashes.

```ruby
pub = Shaolin::Kernel["redis.publisher"]
pub.publish(Shaolin::Messaging::IntegrationEvent.new(event_type: "users.user_registered", payload: { id: "u1" }))

con = Shaolin::Redis::StreamConsumer.new(pool:, stream: "shaolin:events", group: "billing", consumer: "w1")
con.run { |env| command_bus.call(map_to_command(env)) }   # at-least-once → idempotent
```

**Pub/Sub (fire-and-forget)** — `Shaolin::Redis::PubSub` for ephemeral fan-out (live dashboards,
cache invalidation, presence). No persistence, no acks.

## Wiring

```ruby
Shaolin::Redis.register_provider!(url: ENV["REDIS_URL"], namespace: "myapp")
```
registers `redis.pool`, `redis.cache`, `cache.store`, `redis.store`, `redis.publisher` in the kernel.

## Tests

Run against a live Redis (no mocks):

```bash
redis-server --port 6399 --daemonize yes --save ""
REDIS_TEST_URL=redis://127.0.0.1:6399/0 bundle exec rspec
ruby examples/redis/verify.rb        # end-to-end: cache + store + broker
```

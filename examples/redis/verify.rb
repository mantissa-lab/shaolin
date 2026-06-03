require "shaolin/redis"
require "shaolin/messaging"

# Exercises Redis in all three roles against a live server. Start one with:
#   redis-server --port 6399 --daemonize yes --save ""
# (override with REDIS_URL).
url  = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6399/0")
pool = Shaolin::Redis::Connection.pool(url: url)
pool.with { |r| r.flushdb }

puts "== 1. CACHE (cache-aside with TTL) =="
cache = Shaolin::Redis::Cache.new(pool: pool, namespace: "demo:cache")
computed = 0
2.times do
  val = cache.fetch("user:1:profile", ttl: 300) { computed += 1; { name: "Neo", plan: "pro" } }
  puts "  fetch -> #{val.inspect}"
end
raise "cache should compute once" unless computed == 1
puts "  ✔ computed once, served from cache the second time"

puts "\n== 2. STORE (Redis as a database) =="
store = Shaolin::Redis::Store.new(pool: pool, namespace: "demo:store")
store.set("user:1", { id: "1", name: "Neo" })
store.hset("session:abc", "user_id", "1")
store.increment("signups:2026-06")
puts "  get user:1      -> #{store.get('user:1').inspect}"
puts "  hgetall session -> #{store.hgetall('session:abc').inspect}"
puts "  signups counter -> #{store.increment('signups:2026-06')}"
raise "store round-trip" unless store.get("user:1") == { id: "1", name: "Neo" }
puts "  ✔ key/value, hashes, and counters persisted"

puts "\n== 3. BROKER (Streams + consumer group, at-least-once) =="
publisher = Shaolin::Redis::StreamPublisher.new(pool: pool, stream: "demo:events")
consumer  = Shaolin::Redis::StreamConsumer.new(
  pool: pool, stream: "demo:events", group: "billing", consumer: "worker-1", block_ms: 100
)
consumer.ensure_group! # join before publishing
publisher.publish(Shaolin::Messaging::IntegrationEvent.new(event_type: "users.user_registered", payload: { id: "u-1" }))
puts "  published users.user_registered"

received = []
n = consumer.poll { |env| received << env }
puts "  consumed #{n}: #{received.first.inspect}"
raise "broker round-trip" unless n == 1 && received.first[:payload] == { id: "u-1" }
raise "should ack" unless consumer.poll { |_| } == 0
puts "  ✔ delivered to the consumer group and acked (no redelivery)"

puts "\n✅ shaolin Redis end-to-end OK — cache, store, and broker all working"

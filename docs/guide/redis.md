# Redis: cache, store, broker

The `shaolin-redis` gem wires Redis into shaolin in **three roles**, all on top of
[`redis-rb`](https://github.com/redis/redis-rb) (pure Ruby) and a shared
[`connection_pool`](https://github.com/mperham/connection_pool):

| Role | Class | Port it implements | Use for |
|------|-------|--------------------|---------|
| **Cache** | `Shaolin::Redis::Cache` | `Shaolin::Cache` | disposable, TTL'd, shared-across-processes cache-aside |
| **Store** | `Shaolin::Redis::Store` | `Shaolin::Store` | Redis-as-a-database: read models, sessions, flags, counters, LLM state |
| **Broker** | `Shaolin::Redis::StreamPublisher` / `StreamConsumer` | `Shaolin::Messaging::Publisher` (publisher) | reliable, at-least-once delivery via Streams + consumer groups |
| **Broker (ephemeral)** | `Shaolin::Redis::PubSub` | — | fire-and-forget fan-out (no persistence, no acks) |

`require "shaolin/redis"` (or `require "shaolin"`) loads everything. The `:redis`
provider registers the cache/store/broker into the kernel by documented keys.

```ruby
require "shaolin/redis"
```

`Shaolin::Redis::VERSION # => "0.1.0"`.

> **Namespace gotcha.** Inside the `Shaolin::Redis` namespace, a bare `Redis`
> resolves to **this module**, not the `redis-rb` client. The code always uses
> `::Redis` for the real client (e.g. `::Redis.new`, `::Redis::CommandError`).

---

## 1. Connection — pool & single client

`Shaolin::Redis::Connection` (a `module_function` module) builds clients. Both the
cache, store, and publisher share one pool; blocking ops (Pub/Sub `subscribe`) get
their own dedicated client.

| Const | Value |
|-------|-------|
| `Connection::DEFAULT_URL` | `ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")` (resolved at load time) |

### `Connection.pool(url: DEFAULT_URL, size: 5, timeout: 5) → ConnectionPool`
Build a bounded `ConnectionPool` of `::Redis` clients so fiber/thread workers share
a fixed number of connections. `timeout` is seconds to wait for a free connection.

```ruby
pool = Shaolin::Redis::Connection.pool(url: "redis://127.0.0.1:6379/0", size: 10)
pool.with { |r| r.ping } # => "PONG"
```

### `Connection.client(url: DEFAULT_URL) → ::Redis`
A single, un-pooled client — for blocking operations like Pub/Sub `subscribe` that
must own their connection for the whole call.

```ruby
client = Shaolin::Redis::Connection.client
client.set("k", "v")
```

| ENV var | Default | Used by |
|---------|---------|---------|
| `REDIS_URL` | `redis://127.0.0.1:6379/0` | `DEFAULT_URL` (production/dev) |
| `REDIS_TEST_URL` | `redis://127.0.0.1:6399/0` | the gem's specs only (`spec_helper.rb`) |

---

## 2. Cache — `Shaolin::Redis::Cache`

Redis-backed implementation of the `Shaolin::Cache` port. Values are stored as
**JSON**, so primitives/arrays/hashes round-trip; on read, hashes come back with
**symbol keys** (`JSON.parse(symbolize_names: true)`) — matching DTOs, params, and
Store. TTL is delegated to Redis (`SET … EX`), so expiry is **shared across all
processes**, unlike the in-memory `Shaolin::Cache::Memory` adapter. Keys are
namespaced (`"<namespace>:<key>"`) so `clear`/scan stay scoped.

### `new(pool:, namespace: "cache")`
`pool` is a `ConnectionPool`. `namespace` prefixes every key.

```ruby
pool  = Shaolin::Redis::Connection.pool
cache = Shaolin::Redis::Cache.new(pool: pool, namespace: "myapp:cache")
```

### Methods

| Method | Signature | Purpose / returns |
|--------|-----------|-------------------|
| `read` | `read(key, now: nil)` | JSON-decoded value (symbol-keyed), or `nil` on miss. `now:` is accepted for port compatibility but ignored (Redis owns expiry). |
| `write` | `write(key, value, ttl: nil)` | JSON-encode & `SET`; with `ttl:` (seconds) uses `SET … EX ttl`. Returns the **value** (not the Redis reply). |
| `exist?` | `exist?(key, now: nil)` | `true`/`false` via Redis `EXISTS`. |
| `delete` | `delete(key)` | `DEL`; returns number of keys removed (`Integer`). |
| `clear` | `clear` | `SCAN`-iterates `"<namespace>:*"` and `DEL`s them — only this namespace. |
| `fetch` | `fetch(key, ttl: nil, now: Time.now)` | **From the port.** Cache-aside: return cached value, else `yield`, `write(ttl:)`, and return it. |

```ruby
# cache-aside: block runs once, second call is a HIT
user = cache.fetch("user:1", ttl: 300) { load_user(1) }

cache.write("temp", { a: 1, b: [1, 2] }, ttl: 50)
cache.read("temp")   # => {a: 1, b: [1, 2]}   (symbol keys)
cache.exist?("nope") # => false
cache.read("nope")   # => nil
cache.clear          # wipes only "myapp:cache:*"
```

> **Gotcha.** `fetch` only re-computes on a `nil` read. A cached `false`/`0`/`""`
> is a HIT and is returned as-is. `clear` uses `SCAN` (cursor-based, safe on large
> keyspaces) — not `KEYS`.

---

## 3. Store — `Shaolin::Redis::Store`

Redis **as a database**: a namespaced KV + hash store with JSON values, plus native
integer counters. Distinct from `Cache`: the Store is a **source of truth** (no
implicit TTL), the Cache is disposable. Implements the `Shaolin::Store` port (so
`Shaolin::Store::Memory` is a drop-in for tests). Keys are namespaced `"<ns>:<key>"`.

### `new(pool:, namespace: "store")`

```ruby
store = Shaolin::Redis::Store.new(pool: pool, namespace: "myapp:store")
```

### Key/value (JSON)

| Method | Signature | Purpose |
|--------|-----------|---------|
| `set` | `set(key, value, ttl: nil)` | JSON-encode & `SET`; with `ttl:` seconds → `SET … EX`. Returns the **value**. |
| `get` | `get(key)` | JSON-decoded value (symbol keys), or `nil`. |
| `delete` | `delete(key)` | `DEL`; returns count removed. |
| `exists?` | `exists?(key)` | `true`/`false`. |

### Counters (native integer — not JSON)

| Method | Signature | Purpose |
|--------|-----------|---------|
| `increment` | `increment(key, by: 1, ttl: nil)` | `INCRBY`; returns the new `Integer`. `ttl:` sets expiry **only on first creation** (when `count == by`) — an atomic fixed-window counter for rate limits. |
| `decrement` | `decrement(key, by: 1)` | `DECRBY`; returns the new `Integer`. |

### Hashes (a "row" with named, JSON-valued fields)

| Method | Signature | Purpose |
|--------|-----------|---------|
| `hset` | `hset(key, field, value)` | `HSET` field to JSON-encoded `value`; returns Redis reply (`1` new field, `0` updated). |
| `hget` | `hget(key, field)` | JSON-decoded field value (symbol keys), or `nil`. |
| `hgetall` | `hgetall(key)` | Whole hash as `{ field_symbol => decoded_value }`. |

### Iteration

| Method | Signature | Purpose |
|--------|-----------|---------|
| `keys` | `keys(pattern = "*")` | `SCAN`-matches `"<ns>:<pattern>"`, returns keys **with the namespace prefix stripped**. Cursor-based — safe on large keyspaces. |

```ruby
store.set("user:1", { id: "1", name: "Neo" })
store.get("user:1")        # => {id: "1", name: "Neo"}
store.exists?("user:1")    # => true

store.increment("hits")        # => 1
store.increment("hits", by: 4) # => 5
store.decrement("hits", by: 2) # => 3

# fixed-window rate limit: TTL set once, on the first hit of the window
store.increment("rl:user:1", ttl: 60) # => 1 (expires in 60s)

store.hset("session:abc", "user_id", "u-1")
store.hset("session:abc", "roles", %w[admin editor])
store.hget("session:abc", "roles")  # => ["admin", "editor"]
store.hgetall("session:abc")        # => {user_id: "u-1", roles: ["admin", "editor"]}

store.keys # => ["user:1", "session:abc", ...]  (no namespace prefix)
```

> **Gotcha.** Counters are stored as native Redis integers via `INCRBY`/`DECRBY` —
> do **not** mix `set`/`get` (JSON) with `increment`/`decrement` on the same key.
> Re-calling `increment(key, ttl:)` after the window started does **not** reset the
> TTL (only the creating call, where `count == by`, sets it).

---

## 4. Broker — Streams (reliable)

Redis Streams give **at-least-once** delivery with consumer groups and acks. The
publisher implements `Shaolin::Messaging::Publisher`, so it is a drop-in swap for the
RabbitMQ or in-memory publisher. Reactors publish through the outbox, so delivery
stays reliable across crashes. **Handlers must be idempotent** (at-least-once).

### `Shaolin::Redis::StreamPublisher`

#### `new(pool:, stream: "shaolin:events", maxlen: 100_000)`
`maxlen` caps the stream length via **approximate** `XADD … MAXLEN ~` trimming so it
can't grow unbounded.

#### `publish(integration_event) → integration_event`
`XADD`s a 2-field entry — `{ "event_type" => …, "body" => integration_event.to_json }`
— and returns the event. `integration_event` must respond to `event_type` and
`to_json` (e.g. `Shaolin::Messaging::IntegrationEvent`).

```ruby
pub = Shaolin::Redis::StreamPublisher.new(pool: pool, stream: "myapp:events")
evt = Shaolin::Messaging::IntegrationEvent.new(event_type: "users.user_registered", payload: { id: "u1" })
pub.publish(evt)
```

### `Shaolin::Redis::StreamConsumer`

Reads via a consumer group (`XREADGROUP` / `XACK`). Each **group** sees every message
once; multiple **consumers** in a group share the load without double-processing
(Redis tracks pending entries per consumer). Crashed consumers' un-acked entries are
recoverable with `reclaim` (`XAUTOCLAIM`). Each yielded envelope is the parsed
`body` (`JSON.parse(symbolize_names: true)`) — typically mapped to a Command on the
app's own bus (same write path as HTTP).

#### `new(pool:, stream: "shaolin:events", group:, consumer:, count: 10, block_ms: 2000)`
`group` and `consumer` are **required**. `count` is the max entries per read;
`block_ms` is how long `XREADGROUP` blocks waiting for new entries.

| Method | Signature | Purpose / returns |
|--------|-----------|-------------------|
| `ensure_group!` | `ensure_group!(start: "$")` | Idempotently `XGROUP CREATE … MKSTREAM` (swallows `BUSYGROUP`). `start: "$"` = only **new** messages from now; `"0"` = from the beginning. |
| `poll` | `poll { \|envelope\| … }` | One read→handle→ack cycle. Calls `ensure_group!`, `XREADGROUP ">"`, yields each parsed envelope, `XACK`s it. Returns count processed (`0` if none). |
| `run` | `run { \|envelope\| … }` | `ensure_group!`, then loops `poll` until `SIGTERM`/`SIGINT` (graceful: finishes the in-flight batch). |
| `reclaim` | `reclaim(idle_ms: 60_000) { \|envelope\| … }` | `XAUTOCLAIM` entries pending (un-acked) longer than `idle_ms` from crashed consumers, handle + `XACK` them. Returns count reclaimed. |

```ruby
con = Shaolin::Redis::StreamConsumer.new(
  pool: pool, stream: "myapp:events", group: "billing", consumer: "worker-1"
)
con.ensure_group! # subscribe to new messages BEFORE publishing

# one cycle (great for tests — no infinite loop)
con.poll do |env|
  env[:event_type]  # => "users.user_registered"
  env[:payload]     # => {id: "u1"}
end

# long-running worker (blocks until SIGTERM/INT)
con.run { |env| dispatch_command(env) }

# recover work from a crashed consumer
recovered = con.reclaim(idle_ms: 30_000) { |env| dispatch_command(env) }
```

> **Gotchas.**
> - Call `ensure_group!` **before** the first `publish` if you want to receive that
>   message — with the default `start: "$"`, a group created after the `XADD` won't
>   see it. `poll`/`run`/`reclaim` all call `ensure_group!` first (idempotent).
> - At-least-once ⇒ make handlers idempotent. A handler that raises before `XACK`
>   leaves the entry pending; `reclaim` (or another `poll` after the consumer is
>   considered idle) re-delivers it.
> - `reclaim` scans from cursor `"0-0"` up to `count` entries per call.

---

## 5. Broker — Pub/Sub (ephemeral) — `Shaolin::Redis::PubSub`

Lightweight fire-and-forget `PUBLISH`/`SUBSCRIBE`. Messages are **not persisted** —
an offline subscriber misses them, and there are no acks. Use for ephemeral fan-out
(live dashboards, cache invalidation, presence). For reliable delivery use Streams.

### `new(pool:, url: nil)`
`pool` is used for `publish`. `url` (falls back to `Connection::DEFAULT_URL`) is used
for the dedicated `subscribe` connection.

### `publish(channel, message) → Integer`
`PUBLISH`; returns the number of subscribers that received it. A non-`String`
`message` is JSON-encoded; a `String` is sent verbatim.

### `subscribe(*channels, timeout: nil) { |channel, message| … }`
Blocks on a **dedicated** connection (subscribe owns its socket; the connection is
`close`d in `ensure`). With `timeout:` (seconds) it raises `::Redis::TimeoutError`
after silence (`subscribe_with_timeout`) — pass it so tests/shutdown don't hang
forever. Yields `(channel, message)` as raw strings (no JSON decode on the receive
side).

```ruby
ps = Shaolin::Redis::PubSub.new(pool: pool, url: "redis://127.0.0.1:6379/0")

# subscriber (own thread — subscribe blocks)
Thread.new do
  ps.subscribe("room", timeout: 2) { |ch, msg| puts "#{ch}: #{msg}" }
rescue ::Redis::TimeoutError
  # raised after `timeout` seconds of silence
end

ps.publish("room", "ping")     # => 1 (one live subscriber); sent verbatim
ps.publish("room", { a: 1 })   # JSON-encoded → subscriber receives '{"a":1}'
ps.publish("empty", "hi")      # => 0 (nobody listening)
```

> **Gotcha.** `publish` only returns `> 0` once a subscriber is actually registered;
> the spec polls `sleep 0.05 until ps.publish(...) == 1` to avoid a race. `subscribe`
> does not JSON-decode — decode in your block if you published a non-String.

---

## 6. The `:redis` provider

`Shaolin::Redis.register_provider!` builds one shared pool and registers the cache,
store, and broker into `Shaolin::Kernel` so any module resolves them by key. It also
registers a `Shaolin::Health` check (`"redis"`) that `PING`s.

### `Shaolin::Redis.register_provider!(url: Connection::DEFAULT_URL, namespace: "shaolin", pool_size: 5, stream: "shaolin:events")`

| Kwarg | Default | Effect |
|-------|---------|--------|
| `url` | `Connection::DEFAULT_URL` (`REDIS_URL`) | Redis URL for the shared pool |
| `namespace` | `"shaolin"` | cache uses `"<namespace>:cache"`, store uses `"<namespace>:store"` |
| `pool_size` | `5` | pool size |
| `stream` | `"shaolin:events"` | stream the registered publisher writes to |

Registered kernel keys:

| Key | Object |
|-----|--------|
| `redis.pool` | the `ConnectionPool` (raw client access) |
| `redis.cache` | `Shaolin::Redis::Cache` |
| `cache.store` | the generic cache port — **same object** as `redis.cache` (swap backends here) |
| `redis.store` | `Shaolin::Redis::Store` |
| `redis.publisher` | `Shaolin::Redis::StreamPublisher` (the `Messaging::Publisher` port) |

```ruby
# config/boot.rb — order-independent; the provider only needs the kernel
Shaolin::Redis.register_provider!(namespace: "myapp", pool_size: 10)
Shaolin::Provider.start_all

cache = Shaolin::Kernel["cache.store"]          # generic port → Redis cache
cache.write("hello", "world")
cache.read("hello")                              # => "world"

Shaolin::Kernel["redis.store"].set("flag:x", true)
Shaolin::Kernel["redis.publisher"].publish(my_integration_event)
Shaolin::Kernel["redis.pool"].with { |r| r.dbsize }
```

The provider does **not** register a `StreamConsumer` or `PubSub` — construct those
yourself from `Shaolin::Kernel["redis.pool"]` (consumers need a `group`/`consumer`,
and Pub/Sub needs its own blocking connection).

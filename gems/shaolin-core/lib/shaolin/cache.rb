module Shaolin
  # The cache port. Domain code and read models depend only on this interface;
  # a concrete adapter (e.g. Shaolin::Redis::Cache) binds it to a backend. In a
  # monolith/dev/test the in-memory Memory adapter is enough — swapping in Redis
  # is a one-line provider change. `now:` is injectable so TTL is testable.
  module Cache
    def read(_key, now: Time.now)
      raise NotImplementedError, "#{self.class} must implement #read"
    end

    def write(_key, _value, ttl: nil)
      raise NotImplementedError, "#{self.class} must implement #write"
    end

    def delete(_key)
      raise NotImplementedError, "#{self.class} must implement #delete"
    end

    def exist?(key, now: Time.now)
      !read(key, now: now).nil?
    end

    def clear
      raise NotImplementedError, "#{self.class} must implement #clear"
    end

    # Cache-aside: return the cached value, or compute it via the block, store it
    # (with an optional ttl in seconds), and return it.
    def fetch(key, ttl: nil, now: Time.now)
      cached = read(key, now: now)
      return cached unless cached.nil?

      write(key, yield, ttl: ttl)
    end

    # Process-local cache with optional per-key TTL (lazy expiry on read). Not
    # shared across processes — for that use Shaolin::Redis::Cache.
    class Memory
      include Cache

      Entry = Struct.new(:value, :expires_at)

      def initialize
        @store = {}
      end

      def read(key, now: Time.now)
        entry = @store[key]
        return nil unless entry
        if entry.expires_at && now >= entry.expires_at
          @store.delete(key)
          return nil
        end
        entry.value
      end

      def write(key, value, ttl: nil)
        @store[key] = Entry.new(value, ttl && Time.now + ttl)
        value
      end

      def delete(key) = @store.delete(key)
      def clear = @store.clear
    end
  end
end

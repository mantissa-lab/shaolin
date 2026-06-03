require "shaolin/core"
require "shaolin/messaging"

require_relative "redis/version"
require_relative "redis/connection"
require_relative "redis/cache"
require_relative "redis/store"
require_relative "redis/stream_publisher"
require_relative "redis/stream_consumer"
require_relative "redis/pubsub"
require_relative "redis/provider"

module Shaolin
  # Redis integration for shaolin, in three roles:
  #   - Cache  (Shaolin::Redis::Cache — implements the Shaolin::Cache port)
  #   - Store  (Shaolin::Redis::Store — Redis as a key-value/hash database)
  #   - Broker (StreamPublisher/StreamConsumer — reliable, consumer groups;
  #             PubSub — fire-and-forget)
  # All built on redis-rb (pure Ruby). The :redis provider wires them into the
  # kernel. See Shaolin::Redis.register_provider!.
  module Redis
  end
end

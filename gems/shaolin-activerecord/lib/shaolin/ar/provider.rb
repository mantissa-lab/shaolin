require "shaolin/core"
require_relative "connection"
require_relative "event_store_schema"
require_relative "event_repository"

module Shaolin
  module AR
    # Registers the `:active_record` provider. It connects, ensures the
    # event-store schema exists, and publishes the durable event-store backend
    # into the kernel as `cqrs.event_store_backend` — which the `:cqrs` provider
    # then wraps. Register this provider BEFORE `:cqrs` so the backend is present
    # when cqrs boots (otherwise cqrs falls back to in-memory).
    def self.register_provider!(config:, isolation_level: :thread)
      Shaolin.register_provider(:active_record) do
        start do
          Connection.establish!(config)
          Connection.isolation_level = isolation_level
          EventStoreSchema.create!
          Shaolin::Kernel.register("cqrs.event_store_backend", Shaolin::AR.event_repository)
        end

        stop do
          ::ActiveRecord::Base.connection_handler.clear_all_connections!
        rescue StandardError
          nil
        end
      end
    end
  end
end

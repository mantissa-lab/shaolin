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
    # Guards boot-time schema creation so concurrent replica boots don't race
    # (table_exists?-then-create is not itself atomic).
    SCHEMA_LOCK_KEY = 7_283_010

    # auto_schema: create the event-store schema at boot (advisory-locked).
    # Convenient in dev/test; set false in production and run `shaolin migrate`
    # as a release step instead.
    def self.register_provider!(config:, isolation_level: :thread, auto_schema: true)
      Shaolin.register_provider(:active_record) do
        start do
          Connection.establish!(config)
          Connection.isolation_level = isolation_level
          Connection.with_advisory_lock(SCHEMA_LOCK_KEY) { EventStoreSchema.create! } if auto_schema
          Shaolin::Kernel.register("cqrs.event_store_backend", Shaolin::AR.event_repository)
          # The transaction runner that makes the transactional outbox atomic:
          # the :cqrs provider wires it into the aggregate repository so append +
          # sync subscribers (projections + outbox enqueue) commit as one.
          Shaolin::Kernel.register("cqrs.transaction", ->(&blk) { ::ActiveRecord::Base.transaction(&blk) })
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

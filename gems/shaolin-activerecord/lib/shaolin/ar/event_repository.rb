require "ruby_event_store"
require "ruby_event_store/active_record"

module Shaolin
  module AR
    # The durable event-store backend injected into shaolin-cqrs. Uses the
    # PostgreSQL-linearized repository (advisory locks → a consistent global
    # event order under concurrent writers) with the YAML serializer.
    def self.event_repository(serializer: RubyEventStore::Serializers::YAML)
      RubyEventStore::ActiveRecord::PgLinearizedEventRepository.new(serializer: serializer)
    end
  end
end

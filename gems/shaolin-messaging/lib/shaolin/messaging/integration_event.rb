require "json"

module Shaolin
  module Messaging
    # The versioned envelope that crosses the wire. Domain events are NEVER
    # published verbatim — a reactor maps a domain event to a curated
    # integration event, so internal refactors don't break consumers.
    class IntegrationEvent
      attr_reader :event_type, :schema_version, :occurred_at, :correlation_id, :producer, :payload

      def initialize(event_type:, payload: {}, schema_version: 1, occurred_at: nil,
                     correlation_id: nil, producer: nil)
        @event_type = event_type
        @payload = payload
        @schema_version = schema_version
        @occurred_at = occurred_at
        @correlation_id = correlation_id
        @producer = producer
      end

      def to_h
        {
          event_type: event_type,
          schema_version: schema_version,
          occurred_at: occurred_at,
          correlation_id: correlation_id,
          producer: producer,
          payload: payload
        }
      end

      def to_json(*) = JSON.generate(to_h)
    end
  end
end

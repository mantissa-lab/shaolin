require_relative "messaging/version"
require_relative "messaging/integration_event"
require_relative "messaging/publisher"
require_relative "messaging/reactor"

module Shaolin
  # Transport-agnostic messaging ports. Domain logic and reactors depend only on
  # these; a concrete adapter (shaolin-rabbitmq via bunny) binds them to a broker.
  # In a monolith the InMemoryPublisher is enough — flipping on a broker adapter is
  # the monolith -> microservice switch.
  module Messaging
    # The topic an integration event is published to. The event_type already
    # follows a dotted convention (e.g. "users.user_registered"), so it doubles
    # as the topic name.
    def self.topic_for(name_or_event)
      name_or_event.respond_to?(:event_type) ? name_or_event.event_type.to_s : name_or_event.to_s
    end
  end
end

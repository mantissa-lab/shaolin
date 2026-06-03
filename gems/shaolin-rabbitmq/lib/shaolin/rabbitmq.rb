require_relative "rabbitmq/version"
require_relative "rabbitmq/publisher"
require_relative "rabbitmq/consumer"

module Shaolin
  # RabbitMQ transport for shaolin (via bunny — pure Ruby, no system libs).
  # Publisher implements the Messaging::Publisher port; Consumer maps inbound
  # messages to commands. Reactors publish through the outbox, so delivery is
  # reliable (at-least-once) even across crashes.
  module RabbitMQ
  end
end

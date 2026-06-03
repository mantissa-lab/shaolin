require "shaolin/jobs"
require "shaolin/messaging"

module Signups
  module Reactors
    # Async side effect for SignupCompleted: publish an integration event for
    # other services. Runs in `shaolin worker` via the transactional outbox, not
    # in the write transaction — so the HTTP request returns fast and the effect
    # is retried until it succeeds. At-least-once delivery → idempotent by design
    # (the integration event carries the signup id as its key).
    class NotifyReactor < Shaolin::Jobs::Reactor
      on(Signups::Events::SignupCompleted) do |event|
        Shaolin::Kernel["messaging.publisher"].publish(
          Shaolin::Messaging::IntegrationEvent.new(
            event_type: "signups.signup_completed",
            payload: { id: event.data[:id], email: event.data[:email] }
          )
        )
      end
    end
  end
end

require "shaolin/cqrs"
require_relative "events/user_registered"

module Users
  # Event-sourced aggregate. State is derived by replaying events.
  class User
    include Shaolin::CQRS::Aggregate

    def register(name:, email:)
      apply(Events::UserRegistered.new(data: { id: id, name: name, email: email }))
    end

    on(Events::UserRegistered) { |_event| } # no in-memory state needed for this demo
  end
end

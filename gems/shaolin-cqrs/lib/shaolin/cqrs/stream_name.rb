module Shaolin
  module CQRS
    # Canonical event-stream name for an aggregate instance:
    # "<AggregateClass>$<id>" (e.g. "Users::User$u1"). Centralized so stream
    # names are never hand-built.
    def self.stream_name(aggregate_class, id)
      "#{aggregate_class.name}$#{id}"
    end
  end
end

require_relative "jobs/version"
require_relative "jobs/schema"
require_relative "jobs/outbox_job"
require_relative "jobs/outbox"
require_relative "jobs/reactor"
require_relative "jobs/worker"
require_relative "jobs/schedules"
require_relative "jobs/schedule_run"
require_relative "jobs/scheduler"
require_relative "jobs/provider"

module Shaolin
  # Reliable async side-effects via a transactional outbox. A `Reactor` enqueues
  # an outbox row in the same DB transaction as the event it reacts to; a worker
  # process later runs the reactor (at-least-once → reactors must be idempotent).
  module Jobs
  end
end

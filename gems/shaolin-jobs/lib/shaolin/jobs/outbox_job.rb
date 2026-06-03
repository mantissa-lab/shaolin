require "active_record"

module Shaolin
  module Jobs
    # One row in the transactional outbox = a pending reactor invocation.
    # status: pending | done | failed (will retry) | dead (exhausted retries).
    class OutboxJob < ::ActiveRecord::Base
      self.table_name = "shaolin_jobs"
    end
  end
end

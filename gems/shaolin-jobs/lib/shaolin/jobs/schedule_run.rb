require "active_record"

module Shaolin
  module Jobs
    # Persisted last-run time per schedule (so cadence survives restarts and is
    # shared across replicas).
    class ScheduleRun < ::ActiveRecord::Base
      self.table_name = "shaolin_schedules"
    end
  end
end

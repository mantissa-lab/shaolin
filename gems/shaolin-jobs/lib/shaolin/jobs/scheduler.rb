require "active_record"
require_relative "schedules"
require_relative "schedule_run"
require_relative "log"

module Shaolin
  module Jobs
    # Runs periodic tasks. A single leader across replicas via a Postgres
    # advisory lock, so each due task fires once per tick even with N schedulers.
    class Scheduler
      ADVISORY_KEY = 7_283_001 # arbitrary, stable key for the scheduler leader lock

      def initialize(schedules: Schedules)
        @schedules = schedules
        @stop = false
      end

      # Become leader (advisory lock); run due schedules; persist last_run.
      # Returns the names that fired ([] if not leader or nothing due).
      def tick(now: Time.now)
        conn = ::ActiveRecord::Base.connection
        return [] unless conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_KEY})")

        begin
          run_due(now)
        ensure
          conn.select_value("SELECT pg_advisory_unlock(#{ADVISORY_KEY})")
        end
      end

      def run(interval: 1.0)
        install_traps
        until @stop
          begin
            tick
          rescue StandardError => e
            # a DB blip or lock error must not kill the scheduler loop
            Log.emit("error", "scheduler.tick_failed", error: e.message)
          end
          sleep(interval)
        end
      end

      def stop! = (@stop = true)

      private

      def run_due(now)
        @schedules.all.each_with_object([]) do |entry, fired|
          run = ScheduleRun.find_or_initialize_by(name: entry.name)
          next unless run.last_run_at.nil? || (now - run.last_run_at) >= entry.interval

          # Record the attempt first so a failing task respects its interval
          # (no per-tick hammering) and, crucially, one bad task is isolated —
          # it can't abort the loop or block the others.
          run.update!(last_run_at: now)
          begin
            entry.block.call
            fired << entry.name
            Log.emit("info", "schedule.fired", name: entry.name)
          rescue StandardError => e
            Log.emit("error", "schedule.failed", name: entry.name, error: e.message)
          end
        end
      end

      def install_traps
        %w[TERM INT].each { |sig| Signal.trap(sig) { @stop = true } }
      end
    end
  end
end

require "yaml"
require_relative "outbox_job"

module Shaolin
  module Jobs
    # The transactional outbox repository. `enqueue` runs inside the event-append
    # transaction (a sync event-store subscriber), so a job is committed atomically
    # with the event that triggered it. The worker claims jobs with
    # `FOR UPDATE SKIP LOCKED` so multiple replicas never run the same job twice.
    class Outbox
      DEFAULT_BACKOFF = [1, 10, 60, 600, 3600].freeze # seconds

      # Idempotent: ON CONFLICT DO NOTHING on the (reactor, event_id) unique
      # index, so re-publishing an event never enqueues a duplicate — and, since
      # this runs as a sync subscriber inside the event-append transaction, a
      # conflict can't abort that transaction (unlike a raising create!).
      def enqueue(reactor:, event:, run_at: Time.now)
        now = Time.now
        OutboxJob.insert_all(
          [{
            reactor: reactor,
            event_id: event.event_id,
            event_type: event.event_type,
            payload: YAML.dump(event.data),
            status: "pending",
            run_at: run_at,
            created_at: now,
            updated_at: now
          }],
          unique_by: %i[reactor event_id]
        )
      end

      # Lock and return up to `limit` due pending jobs. MUST be called inside a
      # transaction; the row locks are held until that transaction ends, so other
      # workers SKIP them and a crash mid-process rolls the job back to pending.
      # Due jobs are new (`pending`) or awaiting a retry (`failed`) past run_at.
      CLAIMABLE = %w[pending failed].freeze

      def claim(limit:, now: Time.now)
        OutboxJob
          .where(status: CLAIMABLE)
          .where("run_at <= ?", now)
          .order(:run_at)
          .limit(limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .to_a
      end

      def mark_done(job)
        job.update!(status: "done", last_error: nil)
      end

      # Retry with backoff (status `failed`, run_at in the future); after
      # max_attempts the job is dead-lettered (`dead`, kept in the table).
      def mark_failed(job, error:, backoff: DEFAULT_BACKOFF, max_attempts: DEFAULT_BACKOFF.size, now: Time.now)
        attempts = job.attempts + 1
        if attempts >= max_attempts
          job.update!(status: "dead", attempts: attempts, last_error: error.to_s)
        else
          delay = backoff[[attempts - 1, backoff.size - 1].min]
          job.update!(status: "failed", attempts: attempts, last_error: error.to_s, run_at: now + delay)
        end
      end

      # --- observability / operations ---

      # Counts by status, e.g. { "pending" => 3, "failed" => 1, "dead" => 0 }.
      # Powers `shaolin jobs stats` and queue-depth metrics.
      def stats
        OutboxJob.group(:status).count
      end

      # Seconds since the oldest still-due pending job was due — the worker-lag
      # signal (a growing value means the worker can't keep up). 0 when nothing due.
      def oldest_pending_age(now: Time.now)
        oldest = OutboxJob.where(status: CLAIMABLE).where("run_at <= ?", now).minimum(:run_at)
        oldest ? (now - oldest).to_f.round(1) : 0.0
      end

      # Dead-lettered jobs (exhausted retries), newest first — to inspect.
      def dead(limit: 50)
        OutboxJob.where(status: "dead").order(updated_at: :desc).limit(limit).to_a
      end

      # Re-queue a dead job for another attempt (after fixing the cause).
      def retry!(id, now: Time.now)
        OutboxJob.where(id: id, status: "dead")
                 .update_all(status: "pending", attempts: 0, last_error: nil, run_at: now)
      end
    end
  end
end

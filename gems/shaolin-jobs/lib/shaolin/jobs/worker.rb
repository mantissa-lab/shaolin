require "yaml"
require "shaolin/core"
require_relative "outbox"
require_relative "outbox_job"
require_relative "log"

module Shaolin
  module Jobs
    # Drains the outbox: claims due jobs (FOR UPDATE SKIP LOCKED), reads the event,
    # runs the reactor, marks done/failed. Failures retry with backoff; exhausted
    # ones are dead-lettered.
    #
    # Two transaction modes (the trade-off matters for IO-bound reactors):
    # - default (batch in ONE transaction): row locks + the transaction are held
    #   for the whole batch. Fine for fast CPU-bound reactors; fewer round-trips.
    # - tx_per_job: each job is claimed + processed + committed in its OWN short
    #   transaction, so a slow outbound call (HTTP to Meta CAPI, etc.) holds a lock
    #   for just that one job and commits independently. Use this for IO-bound
    #   reactors. Tune `batch` (WORKER_BATCH) to bound how many jobs one run_once
    #   drains.
    class Worker
      def initialize(event_store:, outbox: Outbox.new, batch: 20, tx_per_job: false,
                     backoff: Outbox::DEFAULT_BACKOFF, max_attempts: Outbox::DEFAULT_BACKOFF.size)
        @event_store = event_store
        @outbox = outbox
        @batch = batch
        @tx_per_job = tx_per_job
        @backoff = backoff
        @max_attempts = max_attempts
        @stop = false
      end

      # Drain up to `batch` due jobs. Returns the count processed.
      def run_once(now: Time.now)
        @tx_per_job ? drain_per_job(now) : drain_batch(now)
      end

      # Long-running loop with N threads + graceful SIGTERM/INT stop.
      def run(poll_interval: 0.5, threads: 1)
        install_traps
        Array.new(threads) { Thread.new { drain(poll_interval) } }.each(&:join)
      end

      def stop! = (@stop = true)

      private

      # Whole batch in one transaction (locks held across the batch).
      def drain_batch(now)
        processed = 0
        OutboxJob.transaction do
          @outbox.claim(limit: @batch, now: now).each do |job|
            process(job, now)
            processed += 1
          end
        end
        processed
      end

      # Each job in its own short transaction; the lock is held only for that job.
      def drain_per_job(now)
        processed = 0
        while processed < @batch
          claimed = OutboxJob.transaction do
            job = @outbox.claim(limit: 1, now: now).first
            next false unless job

            process(job, now)
            true
          end
          break unless claimed

          processed += 1
        end
        processed
      end

      def drain(poll_interval)
        until @stop
          sleep(poll_interval) if run_once.zero?
        end
      end

      def process(job, now)
        event = load_event(job)
        Object.const_get(job.reactor).new.call(event)
        @outbox.mark_done(job)
        Log.emit("info", "reactor.done", reactor: job.reactor, event_id: job.event_id, event_type: job.event_type)
      rescue StandardError => e
        @outbox.mark_failed(job, error: e, backoff: @backoff, max_attempts: @max_attempts, now: now)
        dead = job.status == "dead"
        Log.emit(dead ? "error" : "warn", dead ? "reactor.dead" : "reactor.retry",
                 reactor: job.reactor, event_id: job.event_id, attempts: job.attempts, error: e.message)
      end

      # The real event from the store; if it has been pruned/archived, fall back
      # to rebuilding it from the outbox row's own YAML payload (self-contained),
      # so a job never gets stuck just because the stream was trimmed.
      def load_event(job)
        @event_store.read.event(job.event_id)
      rescue StandardError => e
        raise unless e.class.name == "RubyEventStore::EventNotFound"

        data = job.payload.to_s.empty? ? {} : YAML.safe_load(job.payload, permitted_classes: [Symbol, Time, Date], aliases: true)
        Object.const_get(job.event_type).new(event_id: job.event_id, data: data)
      end

      def install_traps
        %w[TERM INT].each { |sig| Signal.trap(sig) { @stop = true } }
      end
    end
  end
end

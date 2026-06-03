require "shaolin/core"
require_relative "outbox"
require_relative "outbox_job"

module Shaolin
  module Jobs
    # Drains the outbox: claims due jobs (FOR UPDATE SKIP LOCKED, locks held for
    # the whole batch transaction so other replicas skip them and a crash rolls
    # jobs back), reads the event, runs the reactor, and marks done/failed.
    # Failures retry with backoff; exhausted ones are dead-lettered.
    class Worker
      def initialize(event_store:, outbox: Outbox.new, batch: 20,
                     backoff: Outbox::DEFAULT_BACKOFF, max_attempts: Outbox::DEFAULT_BACKOFF.size)
        @event_store = event_store
        @outbox = outbox
        @batch = batch
        @backoff = backoff
        @max_attempts = max_attempts
        @stop = false
      end

      # Process one batch in a single transaction. Returns the count processed.
      def run_once(now: Time.now)
        processed = 0
        OutboxJob.transaction do
          @outbox.claim(limit: @batch, now: now).each do |job|
            process(job, now)
            processed += 1
          end
        end
        processed
      end

      # Long-running loop with N threads + graceful SIGTERM/INT stop.
      def run(poll_interval: 0.5, threads: 1)
        install_traps
        Array.new(threads) { Thread.new { drain(poll_interval) } }.each(&:join)
      end

      def stop! = (@stop = true)

      private

      def drain(poll_interval)
        until @stop
          sleep(poll_interval) if run_once.zero?
        end
      end

      def process(job, now)
        event = @event_store.read.event(job.event_id)
        Object.const_get(job.reactor).new.call(event)
        @outbox.mark_done(job)
      rescue StandardError => e
        @outbox.mark_failed(job, error: e, backoff: @backoff, max_attempts: @max_attempts, now: now)
      end

      def install_traps
        %w[TERM INT].each { |sig| Signal.trap(sig) { @stop = true } }
      end
    end
  end
end

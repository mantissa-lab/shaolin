require "yaml"
require "shaolin/core"
require_relative "outbox"
require_relative "outbox_job"
require_relative "log"

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

require "yaml"
require "concurrent"
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
      # `listen:` — when idle, wait on a Postgres NOTIFY (Outbox enqueues fire one)
      # so a new job is picked up immediately instead of after the poll interval;
      # polling remains the correctness floor (any missed NOTIFY is caught next
      # tick). `prefer_payload:` — reconstruct the event from the outbox row's own
      # payload instead of reloading it from the store per job (skips a round-trip;
      # off by default since the store is canonical, e.g. after event upcasting).
      def initialize(event_store:, outbox: Outbox.new, batch: 20, tx_per_job: false,
                     backoff: Outbox::DEFAULT_BACKOFF, max_attempts: Outbox::DEFAULT_BACKOFF.size,
                     listen: true, prefer_payload: false)
        @event_store = event_store
        @outbox = outbox
        @batch = batch
        @tx_per_job = tx_per_job
        @backoff = backoff
        @max_attempts = max_attempts
        @listen = listen
        @prefer_payload = prefer_payload
        @stop = Concurrent::AtomicBoolean.new(false)
      end

      # Drain up to `batch` due jobs. Returns the count processed.
      def run_once(now: Time.now)
        @tx_per_job ? drain_per_job(now) : drain_batch(now)
      end

      # Long-running loop on a fixed thread pool + graceful SIGTERM/INT stop. Each
      # pool thread drains until the stop flag flips; then the pool drains and we
      # wait for in-flight work to finish.
      def run(poll_interval: 0.5, threads: 1)
        install_traps
        pool = Concurrent::FixedThreadPool.new(threads)
        threads.times { pool.post { drain(poll_interval) } }
        pool.shutdown
        pool.wait_for_termination
      end

      def stop! = @stop.make_true

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
        until @stop.true?
          next unless safe_run_once.zero?

          @listen ? wait_for_job(poll_interval) : sleep(poll_interval)
        end
      end

      # Block up to `timeout` for a NOTIFY on the jobs channel (woken early by an
      # enqueue). Holds a connection only while idle; any LISTEN/NOTIFY hiccup
      # degrades to a plain poll-interval sleep — NOTIFY is an optimization, not a
      # correctness dependency.
      def wait_for_job(timeout)
        OutboxJob.connection_pool.with_connection do |conn|
          conn.execute("LISTEN #{Outbox::CHANNEL}")
          conn.raw_connection.wait_for_notify(timeout)
        ensure
          begin
            conn.execute("UNLISTEN #{Outbox::CHANNEL}")
          rescue StandardError
            nil
          end
        end
      rescue StandardError
        sleep(timeout)
      end

      # A transient DB/lock error in one poll must not kill the drain loop.
      def safe_run_once
        run_once
      rescue StandardError => e
        Log.emit("error", "worker.run_failed", error: e.message)
        0
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
        return event_from_payload(job) if @prefer_payload && !job.payload.to_s.empty?

        @event_store.read.event(job.event_id)
      rescue StandardError => e
        raise unless e.class.name == "RubyEventStore::EventNotFound"

        event_from_payload(job)
      end

      def event_from_payload(job)
        data = job.payload.to_s.empty? ? {} : YAML.safe_load(job.payload, permitted_classes: [Symbol, Time, Date], aliases: true)
        Object.const_get(job.event_type).new(event_id: job.event_id, data: data)
      end

      def install_traps
        %w[TERM INT].each { |sig| Signal.trap(sig) { @stop.make_true } }
      end
    end
  end
end

require "json"
require "time"

module Shaolin
  # The unified structured logger. Everything in shaolin (HTTP, worker, scheduler,
  # commands, events, the LLM harness) logs through here, as structured records to
  # pluggable SINKS. JSON to stdout in production, human-readable in dev — the
  # 12-factor analogue of Rails' development/production logs.
  #
  # Records carry a fiber/thread-local CONTEXT (request_id, run_id, ...) plus the
  # current tenant, so a single line correlates across the whole request/job.
  #
  # Shipping to a DB (e.g. BigQuery): on GCP, structured JSON on stdout flows into
  # Cloud Logging and a Log Router sink exports it to BigQuery with ZERO app code —
  # the recommended path (see docs/LOGGING.md). For other targets, add a Sinks::Batch
  # subclass. SHAOLIN_LOG=off silences everything (tests).
  module Log
    LEVELS = %i[debug info warn error].freeze

    class << self
      def sinks = (@sinks ||= [default_sink])

      def sinks=(list)
        @sinks = Array(list)
      end

      def add_sink(sink) = (sinks << sink)

      def level = (@level ||= (ENV["SHAOLIN_LOG_LEVEL"] || "info").to_sym)

      def level=(lvl)
        @level = lvl.to_sym
      end

      # Opt-in firehose: when SHAOLIN_LOG_EVERYTHING is set, the buses and event
      # store log every command, query, and domain event (verbose by design).
      def everything? = ENV["SHAOLIN_LOG_EVERYTHING"] == "1" || ENV["SHAOLIN_LOG_EVERYTHING"] == "true"

      def reset!
        @sinks = nil
        @level = nil
        Thread.current[:shaolin_log_context] = nil
      end

      # Fiber/thread-local fields merged into every record emitted inside the block.
      def context = (Thread.current[:shaolin_log_context] ||= {})

      def with(**fields)
        previous = context.dup
        context.merge!(fields)
        yield
      ensure
        Thread.current[:shaolin_log_context] = previous
      end

      def debug(msg, **f) = emit(:debug, msg, **f)
      def info(msg, **f)  = emit(:info, msg, **f)
      def warn(msg, **f)  = emit(:warn, msg, **f)
      def error(msg, **f) = emit(:error, msg, **f)

      def emit(level, msg, **fields)
        return if ENV["SHAOLIN_LOG"] == "off"
        return if LEVELS.index(level).to_i < LEVELS.index(self.level).to_i

        record = { ts: Time.now.utc.iso8601(3), level: level.to_s, msg: msg.to_s }
        record[:tenant] = Shaolin::Tenant.current if defined?(Shaolin::Tenant) && Shaolin::Tenant.current
        record.merge!(Shaolin::Context.to_h) if defined?(Shaolin::Context)
        record.merge!(context).merge!(fields)
        sinks.each { |sink| sink.call(record) }
      end

      private

      def default_sink
        ENV["SHAOLIN_ENV"] == "production" ? Sinks::Stdout.new : Sinks::Pretty.new
      end
    end

    module Sinks
      # Production: one JSON object per line → Cloud Logging / any log collector.
      class Stdout
        def initialize(io = $stdout) = (@io = io)
        def call(record) = @io.puts(JSON.generate(record))
      end

      # Dev: a compact human-readable line.
      class Pretty
        FIXED = %i[ts level msg].freeze
        def initialize(io = $stdout) = (@io = io)

        def call(record)
          extra = record.reject { |k, _| FIXED.include?(k) }.map { |k, v| "#{k}=#{v}" }.join(" ")
          @io.puts("#{record[:ts]} #{record[:level].to_s.upcase.ljust(5)} #{record[:msg]} #{extra}".rstrip)
        end
      end

      # Base for DB/remote sinks: buffer records and flush in batches via the
      # given block, so writes never block the request/job path. Flushes on the
      # size threshold and on explicit #flush; call #start! for periodic flushing.
      class Batch
        def initialize(flush_size: 100, flush_interval: 5, &flusher)
          @flush_size = flush_size
          @flush_interval = flush_interval
          @flusher = flusher
          @buffer = []
          @mutex = Mutex.new
        end

        def call(record)
          batch = nil
          @mutex.synchronize do
            @buffer << record
            batch = @buffer.slice!(0, @buffer.size) if @buffer.size >= @flush_size
          end
          @flusher.call(batch) if batch && !batch.empty?
        end

        def flush
          batch = @mutex.synchronize { @buffer.slice!(0, @buffer.size) }
          @flusher.call(batch) if batch && !batch.empty?
        end

        def start!
          @thread ||= Thread.new do
            loop do
              sleep(@flush_interval)
              flush
            end
          end
        end
      end
    end
  end
end

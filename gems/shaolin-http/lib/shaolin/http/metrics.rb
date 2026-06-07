require "shaolin/core"

module Shaolin
  module HTTP
    # Minimal Prometheus text exposition for /metrics. Always reports `shaolin_up`;
    # when the jobs outbox is wired, reports queue depth by status so you can alert
    # on backlog and dead-letters. This is a baseline — apps add domain series via
    # their own middleware/exporter.
    module Metrics
      module_function

      def render
        lines = ["# TYPE shaolin_up gauge", "shaolin_up 1"]
        db_pool(lines)
        in_flight(lines)
        outbox(lines)
        "#{lines.join("\n")}\n"
      rescue StandardError
        "shaolin_up 0\n"
      end

      # DB pool utilization — the signal that predicts the connection-pool cliff
      # (#20): if `busy` rides at `size` and `waiting` climbs, you're saturated.
      def db_pool(lines)
        return unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connected?

        s = ::ActiveRecord::Base.connection_pool.stat
        lines << "# TYPE shaolin_db_pool gauge"
        %i[size busy idle waiting].each { |k| lines << %(shaolin_db_pool{state="#{k}"} #{s[k] || 0}) }
      rescue StandardError
        nil
      end

      # In-flight HTTP requests + the admission cap (#20): in_flight near max means
      # you're load-shedding (503s) — size the cap from this.
      def in_flight(lines)
        return unless Shaolin::Kernel.key?("http.concurrency")

        c = Shaolin::Kernel["http.concurrency"]
        lines << "# TYPE shaolin_http_in_flight gauge"
        lines << "shaolin_http_in_flight #{c.in_flight}"
        lines << "shaolin_http_concurrency_max #{c.max}"
      end

      # Outbox depth by status + worker lag (age of the oldest due pending job).
      def outbox(lines)
        return unless Shaolin::Kernel.key?("jobs.outbox")

        ob = Shaolin::Kernel["jobs.outbox"]
        stats = ob.stats
        lines << "# HELP shaolin_outbox_jobs Outbox jobs by status"
        lines << "# TYPE shaolin_outbox_jobs gauge"
        %w[pending failed done dead].each do |status|
          lines << %(shaolin_outbox_jobs{status="#{status}"} #{stats.fetch(status, 0)})
        end
        lines << "# TYPE shaolin_outbox_oldest_pending_seconds gauge"
        lines << "shaolin_outbox_oldest_pending_seconds #{ob.oldest_pending_age}"
      end
    end
  end
end

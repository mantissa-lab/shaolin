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
        if Shaolin::Kernel.key?("jobs.outbox")
          stats = Shaolin::Kernel["jobs.outbox"].stats
          lines << "# HELP shaolin_outbox_jobs Outbox jobs by status"
          lines << "# TYPE shaolin_outbox_jobs gauge"
          %w[pending failed done dead].each do |status|
            lines << %(shaolin_outbox_jobs{status="#{status}"} #{stats.fetch(status, 0)})
          end
        end
        "#{lines.join("\n")}\n"
      rescue StandardError
        "shaolin_up 0\n"
      end
    end
  end
end

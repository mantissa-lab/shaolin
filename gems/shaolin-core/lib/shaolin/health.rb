module Shaolin
  # Readiness registry. Providers contribute named checks (the :active_record
  # provider a DB ping, :redis a PING); the HTTP layer exposes them at /readyz so
  # an orchestrator (k8s/Cloud Run) only routes traffic to a replica that can
  # actually reach its dependencies. Liveness (/healthz) stays a static 200.
  module Health
    @checks = {}

    class << self
      # name: a label; block returns truthy when the dependency is reachable.
      def register(name, &check)
        @checks[name.to_s] = check
      end

      def checks = @checks
      def reset! = (@checks = {})

      # [overall_ok, { "database" => true, "redis" => false, ... }]. A check that
      # raises counts as not-ready (never lets an exception escape the probe).
      def status
        results = @checks.transform_values do |check|
          check.call ? true : false
        rescue StandardError
          false
        end
        [results.values.all?, results]
      end
    end
  end
end

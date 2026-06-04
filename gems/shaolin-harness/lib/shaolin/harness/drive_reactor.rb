require "shaolin/core"
require_relative "registry"
require_relative "run"
require_relative "runner"

module Shaolin
  class Harness
    # Durable driver: the worker runs this on each GateEntered (via the outbox),
    # advancing the run one gate. Each advance appends the next GateEntered, which
    # enqueues the next DriveReactor job — so the harness loop self-perpetuates
    # across worker ticks, crash-resumable.
    #
    # Idempotent under at-least-once delivery: it only advances when the event's
    # gate is still the run's current gate (a redelivered/stale GateEntered for an
    # already-passed gate is skipped), and never touches a terminal run.
    class DriveReactor
      def call(event)
        run_id = event.data[:run_id]
        repo = Shaolin::Kernel["cqrs.aggregate_repository"]
        run = repo.load(Run, run_id)
        return if run.terminal?
        return unless run.current_gate == event.data[:gate]

        harness = Registry.fetch(run.harness_name)
        Runner.new(
          harness: harness,
          llm: Shaolin::Kernel["llm.client"],
          repo: repo,
          command_bus: Shaolin::Kernel["cqrs.command_bus"]
        ).advance(run_id)
      end
    end
  end
end

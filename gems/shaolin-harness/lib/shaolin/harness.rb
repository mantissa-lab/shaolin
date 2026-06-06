require "shaolin/core"
require_relative "harness/version"
require_relative "harness/dsl"
require_relative "harness/gate"
require_relative "harness/events"
require_relative "harness/run"
require_relative "harness/runner"
require_relative "harness/registry"
require_relative "harness/drive_reactor"
require_relative "harness/conversation"

module Shaolin
  # Base class for an LLM harness: a gate state machine, event-sourced per run
  # (durable, auditable, replayable). Subclass and declare gates with the DSL;
  # drive it with Shaolin::Harness::Runner (sync) or `shaolin worker` (durable,
  # via register_durable_provider!). Tools are commands on the command bus.
  class Harness
    extend DSL

    def self.inherited(subclass)
      super
      Registry.register(subclass)
    end

    # Durable runtime: subscribe a GateEntered → outbox enqueuer so `shaolin worker`
    # advances runs step-by-step (DriveReactor). Each advance appends the next
    # GateEntered, which enqueues the next step — the loop self-perpetuates and is
    # crash-resumable. Register AFTER :active_record, :cqrs, :jobs, :llm. Run the
    # worker with WORKER_TX_PER_JOB=1 (each gate's LLM call is IO-bound — hold the
    # row lock per job, not per batch).
    def self.register_durable_provider!
      Shaolin.register_provider(:harness) do
        start do
          outbox = Shaolin::Kernel["jobs.outbox"]
          event_store = Shaolin::Kernel["cqrs.event_store"]
          enqueuer = ->(event) { outbox.enqueue(reactor: "Shaolin::Harness::DriveReactor", event: event) }
          event_store.subscribe(enqueuer, to: [Events::GateEntered])
        end
      end
    end
  end
end

require "shaolin/core"
require_relative "harness/version"
require_relative "harness/dsl"
require_relative "harness/gate"
require_relative "harness/run"
require_relative "harness/runner"

module Shaolin
  # Base class for an LLM harness: a gate state machine, event-sourced per run
  # (durable, auditable, replayable). Subclass and declare gates with the DSL;
  # drive it with Shaolin::Harness::Runner (sync or durable). Tools are commands
  # on the command bus. See Shaolin::Harness::DSL.
  class Harness
    extend DSL
  end
end

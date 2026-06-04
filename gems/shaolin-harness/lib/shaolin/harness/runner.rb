require "shaolin/id"
require_relative "run"

module Shaolin
  class Harness
    # Drives a harness's gate state machine over the event-sourced Run.
    #
    # Each `advance` is ONE atomic gate step: the IO (build prompt → call the LLM →
    # dispatch tool commands) happens OUTSIDE the DB transaction, then a single
    # unit_of_work appends the step's events (prompted, responded, tools, and the
    # on_result transition/completion) atomically. So a crash before the commit
    # just replays that step (at-least-once on the LLM/tool calls — keep tools
    # idempotent); a crash after it resumes at the next gate. `run_to_completion`
    # is the synchronous in-process loop; `advance` is the unit a durable worker
    # drives per GateEntered.
    class Runner
      def initialize(harness:, llm:, repo:, command_bus: nil)
        @harness = harness
        @llm = llm
        @repo = repo
        @command_bus = command_bus
      end

      def start(input:, id: Shaolin::Id.generate)
        @repo.unit_of_work(Run.new(id)) do |run|
          run.start(harness: @harness.harness_name, input: input)
          run.enter(@harness.entry_gate.name)
        end
        id
      end

      def advance(id)
        run = load(id)
        return run if run.terminal?

        gate = @harness.gate_for(run.current_gate)
        prompt = build_prompt(gate, run)
        completion = @llm.complete(messages: to_messages(prompt), tools: tool_schemas(gate))
        tool_results = run_tools(gate, completion)

        @repo.unit_of_work(Run.new(id)) do |fresh|
          fresh.prompted(gate.name, prompt)
          fresh.responded(gate.name, completion)
          tool_results.each do |name, args, result|
            fresh.tool_invoked(gate.name, name, args)
            fresh.tool_returned(gate.name, name, result)
          end
          gate.on_result.call(completion, fresh)
        end
        load(id)
      end

      # Synchronous: run from start to a terminal gate in this process.
      def run_to_completion(input:, id: Shaolin::Id.generate)
        start(input: input, id: id)
        advance(id) until load(id).terminal?
        load(id)
      end

      def load(id) = @repo.load(Run, id)

      private

      def build_prompt(gate, run)
        gate.prompt.respond_to?(:call) ? gate.prompt.call(run) : gate.prompt
      end

      def to_messages(prompt)
        prompt.is_a?(Array) ? prompt : [{ role: "user", content: prompt.to_s }]
      end

      def tool_schemas(gate)
        gate.tool_names.map do |n|
          { name: n.to_s, description: "", parameters: { type: "object", properties: {} } }
        end
      end

      def run_tools(gate, completion)
        return [] unless @command_bus

        completion.tool_calls.map do |tc|
          klass = gate.tools[tc[:name].to_sym] or next nil
          result = @command_bus.call(klass.new(**(tc[:arguments] || {})))
          [tc[:name], tc[:arguments], unwrap(result)]
        end.compact
      end

      def unwrap(result)
        return result.value! if result.respond_to?(:value!) && (!result.respond_to?(:success?) || result.success?)
        return result.failure if result.respond_to?(:failure?) && result.failure?

        result
      end
    end
  end
end

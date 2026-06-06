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

      def start(input: nil, id: Shaolin::Id.generate)
        @repo.unit_of_work(Run.new(id)) do |run|
          run.start(harness: @harness.harness_name, input: input,
                    stage: (@harness.initial_stage if @harness.respond_to?(:initial_stage)),
                    edges: (@harness.stage_edges if @harness.respond_to?(:stage_edges)))
          run.enter(@harness.entry_gate.name)
        end
        id
      end

      # A run is "started" once RunStarted has been applied (harness_name set);
      # a fresh/unknown id loads as an empty aggregate.
      def started?(id) = !load(id).harness_name.nil?

      # One autonomous gate step: build prompt → LLM → tools → on_result, appended
      # atomically. A resting `await` gate is a no-op (only an inbound human message
      # proceeds, via #receive), so a conversation never self-perpetuates.
      def advance(id)
        run = load(id)
        return run if run.terminal?

        gate = @harness.gate_for(run.current_gate)
        return run if gate.await?

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

      # One human-paced turn: record the inbound message (so the prompt builder
      # sees it), wake the run into the entry gate, then run the gate machine
      # (autonomous WITHIN the turn) until it rests at an await gate or terminates.
      # Records the turn's user-facing reply + fires the `on_turn` hook. Returns the
      # reply text.
      MAX_TURN_STEPS = 50

      def receive(id, input:)
        entry = @harness.entry_gate.name
        @repo.unit_of_work(Run.new(id)) do |fresh|
          fresh.received(input)
          fresh.transition_to(entry) unless fresh.current_gate == entry
        end

        steps = 0
        until (run = load(id)).terminal? || awaiting?(run)
          advance(id)
          raise Shaolin::Error, "conversation turn exceeded #{MAX_TURN_STEPS} steps (gate cycle?)" if (steps += 1) > MAX_TURN_STEPS
        end
        finish_turn(id, load(id))
        load(id).last_text
      end

      def awaiting?(run)
        return false if run.terminal?

        @harness.gate_for(run.current_gate).await?
      end

      # Synchronous: run from start to a terminal gate (or a resting await gate) in
      # this process. Autonomous harnesses reach a terminal; conversational ones
      # rest at await (use #receive to drive those turn-by-turn).
      def run_to_completion(input: nil, id: Shaolin::Id.generate)
        start(input: input, id: id)
        advance(id) until (r = load(id)).terminal? || awaiting?(r)
        load(id)
      end

      def load(id) = @repo.load(Run, id)

      private

      # Record the turn's user-facing reply (history) and fire the deterministic
      # `on_turn` hook (always-do updates, e.g. stage transition). Skips when the
      # turn produced no text.
      def finish_turn(id, run)
        reply = run.last_text
        return if reply.nil?

        @repo.unit_of_work(Run.new(id)) do |fresh|
          fresh.replied(reply)
          @harness.on_turn.call(reply, fresh) if @harness.respond_to?(:on_turn) && @harness.on_turn
        end
      end

      def build_prompt(gate, run)
        return gate.prompt.respond_to?(:call) ? gate.prompt.call(run) : gate.prompt if gate.prompt
        return @harness.context_for(run) if @harness.respond_to?(:context_for)

        raise Shaolin::Error, "gate #{gate.name.inspect} has no prompt and #{@harness} has no conversational context"
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

require "shaolin/cqrs"
require_relative "events"

module Shaolin
  class Harness
    # The event-sourced harness run: a state machine whose current gate, status,
    # and accumulated context are derived by replaying events. The runtime drives
    # it; a gate's `on_result` block calls `transition_to` / `complete` on it.
    class Run
      include Shaolin::CQRS::Aggregate

      RUNNING = "running"
      COMPLETED = "completed"
      FAILED = "failed"

      def start(harness:, input:)
        apply(Events::RunStarted.new(data: { harness: harness, input: input }))
      end

      def enter(gate)
        apply(Events::GateEntered.new(data: { run_id: id, gate: gate.to_s }))
      end

      def prompted(gate, prompt)
        apply(Events::Prompted.new(data: { gate: gate.to_s, prompt: prompt }))
      end

      def responded(gate, completion)
        apply(Events::Responded.new(data: {
          gate: gate.to_s, text: completion.text,
          tool_calls: completion.tool_calls, usage: completion.usage
        }))
      end

      def tool_invoked(gate, name, arguments)
        apply(Events::ToolInvoked.new(data: { gate: gate.to_s, name: name.to_s, arguments: arguments }))
      end

      def tool_returned(gate, name, result)
        apply(Events::ToolReturned.new(data: { gate: gate.to_s, name: name.to_s, result: result }))
      end

      # Called from a gate's on_result block — records the edge AND enters the
      # next gate (so the durable runtime's GateEntered drive continues).
      def transition_to(gate)
        apply(Events::Transitioned.new(data: { from: @current_gate, to: gate.to_s }))
        enter(gate)
      end

      def complete(output)
        apply(Events::Completed.new(data: { output: output }))
      end

      def fail(error)
        apply(Events::Failed.new(data: { gate: @current_gate, error: error.to_s }))
      end

      attr_reader :harness_name, :input, :current_gate, :status, :output

      def terminal? = [COMPLETED, FAILED].include?(@status)
      def completed? = @status == COMPLETED
      def failed? = @status == FAILED
      def responded?(gate) = responses.key?(gate.to_s)
      def response_for(gate) = responses[gate.to_s]
      def tool_results = (@tool_results ||= [])
      def last_text = @last_text

      on(Events::RunStarted) { |e| @harness_name = e.data[:harness]; @input = e.data[:input]; @status = RUNNING }
      on(Events::GateEntered) { |e| @current_gate = e.data[:gate] }
      on(Events::Prompted) { |_e| }
      on(Events::Responded) { |e| responses[e.data[:gate]] = e.data; @last_text = e.data[:text] }
      on(Events::ToolInvoked) { |_e| }
      on(Events::ToolReturned) { |e| tool_results << { name: e.data[:name], result: e.data[:result] } }
      on(Events::Transitioned) { |e| @current_gate = e.data[:to] }
      on(Events::Completed) { |e| @status = COMPLETED; @output = e.data[:output] }
      on(Events::Failed) { |_e| @status = FAILED }

      private

      def responses = (@responses ||= {})
    end
  end
end

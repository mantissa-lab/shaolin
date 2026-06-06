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

      def start(harness:, input: nil, stage: nil, edges: nil)
        apply(Events::RunStarted.new(data: { run_id: id, harness: harness, input: input, stage: stage, edges: edges }))
      end

      # --- conversational (human-paced) mode -------------------------------

      # Record an inbound human message — the start of a turn. Becomes the latest
      # user entry in the conversation history the prompt builder reads.
      def received(message)
        apply(Events::MessageReceived.new(data: { run_id: id, content: message.to_s }))
      end

      # Stamp app dimensions (geo, device, variant, segment, …) onto the session —
      # merged into run state and projected onto the conversations_read row's tags
      # for cross-user funnel queries. Call from session start, on_result, on_turn.
      def tag(attrs)
        return if attrs.nil? || attrs.empty?

        apply(Events::Tagged.new(data: { run_id: id, tags: attrs }))
      end

      # The turn's user-facing reply (its assistant history entry). Distinct from
      # per-gate `responded` (full audit incl. internal classification gates).
      def replied(text)
        apply(Events::Replied.new(data: { run_id: id, content: text.to_s }))
      end

      # Advance the funnel. STRICT against the declared edges carried on the run:
      # an undeclared jump raises; a no-op when already at `to`. Drive it from a
      # gate's on_result / the harness on_turn (e.g. when the model used an offer
      # tool), so the funnel stage stays on the run aggregate.
      def advance_to(to)
        to = to.to_s
        return if to == @stage

        allowed = @edges ? Array(@edges[@stage]).map(&:to_s) : nil
        if allowed && !allowed.include?(to)
          raise Shaolin::Error,
                "illegal stage transition #{@stage.inspect} → #{to.inspect} (allowed from #{@stage.inspect}: #{allowed})"
        end

        apply(Events::StageChanged.new(data: { run_id: id, from: @stage, to: to }))
      end

      def enter(gate)
        apply(Events::GateEntered.new(data: { run_id: id, gate: gate.to_s }))
      end

      def prompted(gate, prompt)
        apply(Events::Prompted.new(data: { gate: gate.to_s, prompt: prompt }))
      end

      def responded(gate, completion)
        apply(Events::Responded.new(data: {
          gate: gate.to_s, text: completion.text, reasoning: completion.reasoning,
          tool_calls: completion.tool_calls, usage: completion.usage, data: completion.data
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

      attr_reader :harness_name, :input, :current_gate, :status, :output, :stage

      def terminal? = [COMPLETED, FAILED].include?(@status)
      def completed? = @status == COMPLETED
      def failed? = @status == FAILED
      def responded?(gate) = responses.key?(gate.to_s)
      def response_for(gate) = responses[gate.to_s]
      def tool_results = (@tool_results ||= [])
      def last_text = @last_text

      # Conversation history as chat messages ([{role:, content:}], oldest first):
      # human turns (MessageReceived) interleaved with replies (Replied). `recent`
      # returns the last `n` messages (the memory window) — what the prompt builder
      # feeds the model.
      def history = (@history ||= [])
      def recent(n = nil) = n ? history.last(n) : history

      # App dimensions stamped on the session (string keys), e.g. {"geo"=>"DE"}.
      def tags = (@tags ||= {})

      on(Events::RunStarted) do |e|
        @harness_name = e.data[:harness]
        @input = e.data[:input]
        @stage = e.data[:stage] && e.data[:stage].to_s
        @edges = normalize_edges(e.data[:edges])
        @status = RUNNING
      end
      on(Events::GateEntered) { |e| @current_gate = e.data[:gate] }
      on(Events::Prompted) { |_e| }
      on(Events::Responded) { |e| responses[e.data[:gate]] = e.data; @last_text = e.data[:text] }
      on(Events::ToolInvoked) { |_e| }
      on(Events::ToolReturned) { |e| tool_results << { name: e.data[:name], result: e.data[:result] } }
      on(Events::Transitioned) { |e| @current_gate = e.data[:to] }
      on(Events::Completed) { |e| @status = COMPLETED; @output = e.data[:output] }
      on(Events::Failed) { |_e| @status = FAILED }
      on(Events::MessageReceived) { |e| history << { role: "user", content: e.data[:content] } }
      on(Events::Replied) { |e| history << { role: "assistant", content: e.data[:content] }; @last_text = e.data[:content] }
      on(Events::StageChanged) { |e| @stage = e.data[:to] }
      on(Events::Tagged) { |e| tags.merge!(e.data[:tags].transform_keys(&:to_s)) }

      private

      def responses = (@responses ||= {})

      # {from => [to, ...]} with everything stringified (events may round-trip
      # symbol keys to strings); nil when the run declares no funnel.
      def normalize_edges(edges)
        return nil unless edges

        edges.each_with_object({}) { |(from, tos), h| h[from.to_s] = Array(tos).map(&:to_s) }
      end
    end
  end
end

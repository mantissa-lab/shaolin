require_relative "gate"

module Shaolin
  class Harness
    # Class-level DSL for defining a harness as a set of gates. Subclass and
    # declare gates; the Runner drives the resulting state machine.
    #
    #   class Triage < Shaolin::Harness
    #     harness_name "triage"
    #     llm model: "gpt-4.1"
    #     gate :classify, entry: true do
    #       prompt { |run| "Classify: #{run.input[:text]}" }
    #       tools lookup: LookupAccount
    #       on_result { |out, run| run.transition_to(out.tool_used?(:lookup) ? :respond : :reject) }
    #     end
    #     gate :respond, terminal: true do
    #       prompt { |run| "Answer using #{run.tool_results.last[:result]}" }
    #       on_result { |out, run| run.complete(answer: out.text) }
    #     end
    #   end
    module DSL
      def harness_name(value = nil)
        @harness_name = value if value
        @harness_name ||= default_harness_name
      end

      def llm(model: nil)
        @llm_model = model if model
        @llm_model
      end

      def model = @llm_model

      # `to:` (optional) declares the possible next gates for describe/graph; the
      # actual transition is whatever the gate's on_result calls at runtime.
      def gate(name, entry: false, terminal: false, to: [], &block)
        builder = GateBuilder.new(name, entry, terminal, Array(to).map(&:to_s))
        builder.instance_eval(&block)
        gates[name.to_s] = builder.build
      end

      def gates = (@gates ||= {})
      def gate_for(name) = gates.fetch(name.to_s) { raise ArgumentError, "no gate #{name.inspect} in #{self}" }
      def entry_gate = gates.values.find(&:entry) || raise(ArgumentError, "#{self} has no entry gate")

      # Machine-readable map for describe/graph/agents.
      def describe
        {
          name: harness_name,
          model: model,
          gates: gates.values.map do |g|
            { name: g.name, entry: g.entry, terminal: g.terminal,
              tools: g.tool_names.map(&:to_s), to: g.transition_names }
          end
        }
      end

      private

      def default_harness_name
        return "harness" unless name

        name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end

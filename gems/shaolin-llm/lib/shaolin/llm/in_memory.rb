require_relative "client"
require_relative "completion"

module Shaolin
  module LLM
    # Scripted in-process LLM for tests and deterministic harness replay (no
    # network, no keys). Hand it Completions (or hashes) to return in order; it
    # records every call so specs can assert on the prompt/tools sent.
    #
    # Scripted Completions can carry `reasoning:` too, for deterministic harness
    # tests that assert on the persisted reasoning trace.
    #
    #   llm = Shaolin::LLM::InMemory.new(
    #     Shaolin::LLM::Completion.new(text: "billing", reasoning: "user mentions an invoice"),
    #     { text: "done" }
    #   )
    class InMemory
      include Client

      attr_reader :calls

      def initialize(*responses)
        @responses = responses.flatten
        @calls = []
      end

      def complete(messages:, tools: [], model: nil, response_format: nil)
        @calls << { messages: messages, tools: tools, model: model, response_format: response_format }
        response = @responses.shift
        raise "InMemory LLM: no scripted response left (call ##{@calls.size})" unless response

        response.is_a?(Completion) ? response : Completion.new(**response)
      end
    end
  end
end

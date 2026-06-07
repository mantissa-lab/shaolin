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

      def initialize(*responses, speak: [], transcribe: [])
        @responses = responses.flatten
        @speak = speak.dup
        @transcribe = transcribe.dup
        @calls = []
      end

      def complete(messages:, tools: [], model: nil, response_format: nil, params: {})
        @calls << { messages: messages, tools: tools, model: model, response_format: response_format, params: params }
        response = @responses.shift
        raise "InMemory LLM: no scripted response left (call ##{@calls.size})" unless response

        response.is_a?(Completion) ? response : Completion.new(**response)
      end

      def speak(text, voice: nil, format: nil, model: nil)
        @calls << { audio: :speak, text: text, voice: voice, format: format, model: model }
        @speak.shift || raise("InMemory LLM: no scripted speak response left")
      end

      def transcribe(audio, language: nil, model: nil)
        @calls << { audio: :transcribe, bytes: audio, language: language, model: model }
        @transcribe.shift || raise("InMemory LLM: no scripted transcribe response left")
      end
    end
  end
end

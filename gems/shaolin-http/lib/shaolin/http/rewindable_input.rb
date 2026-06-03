require "stringio"

module Shaolin
  module HTTP
    # Buffers a non-rewindable request body (e.g. Falcon's streaming rack.input)
    # into a rewindable StringIO, so both the router and the controller's Request
    # can read it. Rack-test/Puma already provide a rewindable input, so this is
    # a no-op there.
    class RewindableInput
      def initialize(app)
        @app = app
      end

      def call(env)
        input = env["rack.input"]
        if input && !input.is_a?(StringIO)
          buffered = input.read.to_s
          input.rewind if input.respond_to?(:rewind)
          env["rack.input"] = StringIO.new(buffered)
        end
        @app.call(env)
      end
    end
  end
end

require "stringio"
require "json"

module Shaolin
  module HTTP
    # Buffers a non-rewindable request body (e.g. Falcon's streaming rack.input)
    # into a rewindable StringIO, so both the router and the controller's Request
    # can read it. Rack-test/Puma already provide a rewindable input, so buffering
    # is a no-op there.
    #
    # It also caps the body size (default 1 MiB, SHAOLIN_MAX_BODY_BYTES) so an
    # oversized or slow upload can't exhaust memory — a 413 is returned before the
    # whole body is held. Reads at most max+1 bytes to detect the overflow.
    class RewindableInput
      MAX_BODY_BYTES = Integer(ENV.fetch("SHAOLIN_MAX_BODY_BYTES", (1024 * 1024).to_s))

      def initialize(app, max_bytes: MAX_BODY_BYTES)
        @app = app
        @max = max_bytes
      end

      def call(env)
        declared = env["CONTENT_LENGTH"]
        return too_large if declared && declared.to_i > @max

        input = env["rack.input"]
        if input.is_a?(StringIO)
          return too_large if input.size > @max
        elsif input
          buffered = input.read(@max + 1).to_s
          return too_large if buffered.bytesize > @max

          input.rewind if input.respond_to?(:rewind)
          env["rack.input"] = StringIO.new(buffered)
        end

        @app.call(env)
      end

      private

      def too_large
        body = JSON.generate(error: { code: "payload_too_large",
                                      message: "request body exceeds #{@max} bytes" })
        [413, { "content-type" => "application/json" }, [body]]
      end
    end
  end
end

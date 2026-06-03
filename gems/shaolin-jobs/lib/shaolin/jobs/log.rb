require "json"
require "time"

module Shaolin
  module Jobs
    # Structured (JSON) logging for the async side — the worker and scheduler —
    # mirroring the HTTP RequestLogger so reactor failures, dead-letters, and
    # fired schedules are visible in logs (not just the DB). SHAOLIN_LOG=off
    # silences it; inject a different sink with `Log.output=`.
    module Log
      @output = $stdout

      class << self
        attr_accessor :output

        def emit(level, msg, **fields)
          return if ENV["SHAOLIN_LOG"] == "off"

          @output.puts(JSON.generate({ ts: Time.now.utc.iso8601(3), level: level, msg: msg }.merge(fields)))
        end
      end
    end
  end
end

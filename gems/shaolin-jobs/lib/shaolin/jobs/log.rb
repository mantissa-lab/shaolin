require "shaolin/core"

module Shaolin
  module Jobs
    # Thin shim onto the unified Shaolin::Log so the worker/scheduler share one
    # structured pipeline + sinks with the rest of the framework. Kept as a named
    # entry point for the async side (reactor.done/retry/dead, schedule.*).
    module Log
      module_function

      def emit(level, msg, **fields)
        Shaolin::Log.emit(level.to_sym, msg, **fields)
      end
    end
  end
end

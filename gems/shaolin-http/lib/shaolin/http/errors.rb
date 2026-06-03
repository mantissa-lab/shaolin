require "shaolin/core"

module Shaolin
  module HTTP
    # Raised at boot when two modules declare the same verb+path.
    class RouteConflictError < Shaolin::Error; end
  end
end

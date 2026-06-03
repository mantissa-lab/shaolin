require_relative "core/version"
require_relative "errors"
require_relative "config"
require_relative "registry"
require_relative "dsl"

module Shaolin
  # entrypoint; further sub-systems (container builder, injector, providers,
  # app/lifecycle) are required as they are added.
end

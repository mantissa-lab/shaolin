require_relative "config"
require_relative "lifecycle"

module Shaolin
  # The composition root. Boots an application from a project root and exposes
  # each module's isolation-enforcing container.
  class App
    def initialize(root:, env: ENV)
      @config = Config.new(env: env)
      @lifecycle = Lifecycle.new(root: root, config: @config)
    end

    def boot!
      @lifecycle.boot!
      self
    end

    def shutdown! = @lifecycle.shutdown!
    def modules   = @lifecycle.containers.keys
    def [](name)  = @lifecycle.containers.fetch(name.to_s)
  end
end

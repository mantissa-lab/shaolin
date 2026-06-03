require "dry/configurable"

module Shaolin
  # Typed, ENV-sourced application configuration. Per-instance (via
  # `include Dry::Configurable`) so multiple apps/tests don't share state.
  class Config
    include Dry::Configurable

    setting :modules_path, default: "app/modules"
    setting :env, default: "development"

    def initialize(env: ENV)
      config.modules_path = env.fetch("SHAOLIN_MODULES_PATH", "app/modules")
      config.env          = env.fetch("SHAOLIN_ENV", "development")
    end

    def modules_path = config.modules_path
    def env          = config.env
  end
end

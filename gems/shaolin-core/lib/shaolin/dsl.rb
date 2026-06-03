require_relative "module_definition"
require_relative "registry"

module Shaolin
  # The manifest entrypoint: `Shaolin.module("users") { imports ...; exports ... }`.
  def self.module(name, &block)
    defn = ModuleDefinition.new(name)
    defn.instance_eval(&block) if block
    Registry.register(defn)
    defn
  end
end

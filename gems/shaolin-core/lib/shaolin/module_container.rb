require_relative "errors"

module Shaolin
  # A facade over a module's dry-system container that enforces the isolation
  # contract: a module may resolve its own components and the keys it explicitly
  # imported, and nothing else. Imports are registered by the lifecycle's wire
  # phase as resolvers that delegate to the owning module.
  class ModuleContainer
    attr_reader :definition

    def initialize(definition:, container:)
      @definition = definition
      @container = container
      @imports = {}
    end

    def register_import(key, &resolver)
      @imports[key.to_s] = resolver
    end

    def [](key)
      key = key.to_s
      return @container[key] if @container.key?(key)
      return @imports[key].call if @imports.key?(key)

      raise IsolationError.new(consumer: @definition.name, key: key, owner: owner_of(key))
    end

    def key?(key)
      key = key.to_s
      @container.key?(key) || @imports.key?(key)
    end

    def exports?(key) = @definition.exports.include?(key.to_s)

    private

    def owner_of(key) = key.split(".", 2).first
  end
end

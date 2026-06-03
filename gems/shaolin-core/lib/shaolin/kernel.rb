module Shaolin
  # The shared kernel container for framework-wide infrastructure components
  # (e.g. `cqrs.command_bus`, `cqrs.event_store`) registered by providers at
  # boot. Module containers fall back to it, so any module can resolve infra via
  # `Deps[...]` without it being a cross-module dependency. It never holds module
  # exports, so isolation between modules is preserved.
  module Kernel
    UNSET = Object.new.freeze
    private_constant :UNSET

    @components = {}

    class << self
      # Register either an eager value or a lazy block (memoized on first resolve).
      def register(key, value = UNSET, &block)
        @components[key.to_s] = block || -> { value }
        self
      end

      def [](key)
        resolver = @components[key.to_s]
        resolver&.call
      end

      def key?(key) = @components.key?(key.to_s)
      def reset!    = (@components = {})
    end
  end
end

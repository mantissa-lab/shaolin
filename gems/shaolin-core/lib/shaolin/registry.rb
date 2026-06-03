require_relative "errors"

module Shaolin
  # Process-wide registry of module manifests, populated as `module.rb` files
  # are loaded during the discover phase.
  module Registry
    @modules = {}

    class << self
      def register(defn)
        if @modules.key?(defn.name)
          raise ManifestError.new("module already registered", module_name: defn.name)
        end

        @modules[defn.name] = defn
      end

      def find(name) = @modules[name.to_s]
      def names      = @modules.keys
      def all        = @modules.values
      def reset!     = (@modules = {})
    end
  end
end

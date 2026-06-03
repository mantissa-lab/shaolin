module Shaolin
  # Base for all shaolin errors. Exposes a machine-readable contract so that
  # LLM/agent tooling can act on failures uniformly (see LLM-interface spec).
  class Error < StandardError
    def to_contract
      { code: self.class.name.split("::").last, message: message }
    end
  end

  # Raised when a module manifest is structurally invalid (bad export, cycle,
  # duplicate name, unknown import target).
  class ManifestError < Error
    attr_reader :module_name

    def initialize(msg, module_name: nil)
      @module_name = module_name
      super(module_name ? "[#{module_name}] #{msg}" : msg)
    end
  end

  # Raised when a module tries to access a key it did not import, or that the
  # owning module does not export.
  class IsolationError < Error
    def initialize(consumer:, key:, owner:)
      super("module '#{consumer}' may not access '#{key}' " \
            "(owned by '#{owner}'); add an import or use its exports")
    end
  end

  # Raised on boot/provider failures (cycles, unknown providers).
  class BootError < Error; end
end

module Shaolin
  # Typed-ish cross-module access for components (controllers, handlers). Instead
  # of navigating `Kernel["kernel.containers"]["other"]["other.thing"]` by hand —
  # stringly-typed, a typo only blows up (or returns nil) at runtime — call
  # `import("other.thing")`. It resolves via the component's OWN module container
  # (so isolation still holds) and validates the key against what the module's
  # manifest declares in `imports` / `imports events:`, raising a clear error
  # otherwise. `shaolin lint` additionally checks these calls statically.
  module Imports
    def import(key)
      mod = Shaolin::Inflector.underscore(self.class.name.to_s.split("::").first)
      definition = Shaolin::Registry.find(mod)
      declared = definition ? definition.imports + definition.subscribed_events : []
      unless declared.include?(key.to_s)
        raise Shaolin::Error,
              "module #{mod.inspect} does not import #{key.inspect} — declare it in module.rb " \
              "(`imports \"#{key}\"` or `imports events: [\"#{key}\"]`)"
      end

      Shaolin::Kernel["kernel.containers"].fetch(mod)[key]
    end
  end
end

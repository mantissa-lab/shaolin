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

    # Dispatch ANOTHER module's command by dotted key — `dispatch("call.start_call",
    # id:, ...)` — without referencing its constant (lint-clean, like events by
    # topic). The key must be declared in this module's manifest as
    # `imports commands: ["call.start_call"]`; it resolves to `Call::Commands::
    # StartCall` and runs on the shared command bus. Own-module commands stay a
    # direct `command_bus.call(Commands::X.new(...))`.
    def dispatch(key, **args)
      mod = Shaolin::Inflector.underscore(self.class.name.to_s.split("::").first)
      definition = Shaolin::Registry.find(mod)
      declared = definition ? definition.imported_commands : []
      unless declared.include?(key.to_s)
        raise Shaolin::Error,
              "module #{mod.inspect} does not import command #{key.inspect} — declare it in module.rb " \
              "(`imports commands: [\"#{key}\"]`)"
      end

      klass = Object.const_get(Shaolin::Topic.command_class_name(key))
      Shaolin::Kernel["cqrs.command_bus"].call(klass.new(**args))
    end
  end
end

module Shaolin
  # Key normalization for the boundaries where Ruby symbol/string keys diverge.
  # Event data round-trips with SYMBOL keys (the AR event store uses a symbol-safe
  # serializer), and Request params are symbolized — so inside shaolin you can
  # rely on symbol keys. The mismatch shows up at the jsonb edge: an ActiveRecord
  # jsonb column reads back with STRING keys. Use `deep_symbolize` there.
  module Keys
    module_function

    def deep_symbolize(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), out|
          out[k.respond_to?(:to_sym) ? k.to_sym : k] = deep_symbolize(v)
        end
      when Array
        obj.map { |e| deep_symbolize(e) }
      else
        obj
      end
    end
  end
end

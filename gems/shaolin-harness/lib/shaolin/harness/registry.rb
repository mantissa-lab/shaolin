module Shaolin
  class Harness
    # Maps a run's harness_name → its Harness subclass, so the durable
    # DriveReactor (which only has the run's events) can find the definition to
    # advance. Subclasses auto-register on definition.
    module Registry
      @harnesses = []

      class << self
        def register(klass)
          @harnesses << klass unless @harnesses.include?(klass)
        end

        def fetch(harness_name)
          @harnesses.find { |k| k.harness_name == harness_name.to_s } ||
            raise(ArgumentError, "no harness registered with name #{harness_name.inspect}")
        end

        def all = @harnesses.dup
        def reset! = (@harnesses = [])
      end
    end
  end
end

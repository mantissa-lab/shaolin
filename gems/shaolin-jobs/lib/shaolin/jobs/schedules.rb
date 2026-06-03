module Shaolin
  module Jobs
    # Registry of periodic tasks declared with `Shaolin.schedule`.
    module Schedules
      Entry = Struct.new(:name, :interval, :block)
      UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

      @entries = {}

      class << self
        def register(name, interval_seconds, &block)
          @entries[name.to_s] = Entry.new(name.to_s, interval_seconds, block)
        end

        def all   = @entries.values
        def reset! = (@entries = {})

        def parse_interval(str)
          match = str.to_s.match(/\A(\d+)([smhd])\z/)
          raise ArgumentError, "bad interval #{str.inspect} (use e.g. 10s, 1m, 1h, 1d)" unless match

          match[1].to_i * UNITS[match[2]]
        end
      end
    end
  end

  # Module-level DSL: `Shaolin.schedule "retry_dead", every: "1m" do ... end`.
  def self.schedule(name, every:, &block)
    Jobs::Schedules.register(name, Jobs::Schedules.parse_interval(every), &block)
  end
end

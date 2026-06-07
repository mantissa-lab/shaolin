module Shaolin
  # The manifest value object built by `Shaolin.module(name) { ... }`.
  #
  # Each accessor doubles as a DSL writer: called with arguments inside the
  # manifest block it appends; called with none (after the block) it reads.
  # This keeps the manifest DSL terse while exposing a plain reader API.
  class ModuleDefinition
    def initialize(name)
      @name = name.to_s
      @imports = []
      @exports = []
      @commands_handled = []
      @events_published = []
      @subscribed_events = []
      @imported_commands = []
    end

    attr_reader :name

    # `imports "billing.invoice_reader"` (component), `imports events: [...]`
    # (subscribe to another module's events by topic), and `imports commands:
    # [...]` (dispatch another module's commands by dotted key via `dispatch(...)`).
    def imports(*keys, events: [], commands: [])
      return @imports if keys.empty? && events.empty? && commands.empty?

      @imports.concat(keys.flatten.map(&:to_s))
      @subscribed_events.concat(Array(events).map(&:to_s))
      @imported_commands.concat(Array(commands).map(&:to_s))
      self
    end

    # Dotted command keys this module may `dispatch(...)` cross-module.
    def imported_commands = @imported_commands

    def exports(*keys)
      return @exports if keys.empty?

      @exports.concat(keys.flatten.map(&:to_s))
      self
    end

    def commands_handled(*names)
      return @commands_handled if names.empty?

      @commands_handled.concat(names.flatten.map(&:to_s))
      self
    end

    def events_published(*names)
      return @events_published if names.empty?

      @events_published.concat(names.flatten.map(&:to_s))
      self
    end

    def subscribed_events = @subscribed_events
  end
end

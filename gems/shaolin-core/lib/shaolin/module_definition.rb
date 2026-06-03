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
    end

    attr_reader :name

    def imports(*keys, events: [])
      return @imports if keys.empty? && events.empty?

      @imports.concat(keys.flatten.map(&:to_s))
      @subscribed_events.concat(Array(events).map(&:to_s))
      self
    end

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

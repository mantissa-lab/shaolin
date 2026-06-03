require "dry/inflector"

module Shaolin
  # Maps the dotted contract topic (as written in `events_published` and
  # `imports events: [...]`) to its event class name, by the SAME inflection the
  # generator uses (plain Dry::Inflector): the module segment camelizes to the
  # namespace, the event segment to the event class, under `::Events`.
  #
  #   "conversions.conversion_recorded" -> "Conversions::Events::ConversionRecorded"
  #
  # This lets a reactor subscribe to another module's event by STRING (lint-clean,
  # no cross-module constant reference); the :jobs provider resolves the class at
  # wire time.
  module Topic
    INFLECTOR = Dry::Inflector.new

    module_function

    def event_class_name(topic)
      module_part, event_part = topic.to_s.split(".", 2)
      unless event_part && !module_part.to_s.empty?
        raise ArgumentError, "topic must be 'module.event_name', got #{topic.inspect}"
      end

      "#{INFLECTOR.camelize(module_part)}::Events::#{INFLECTOR.camelize(event_part)}"
    end

    # The owning module's name (the segment before the first dot), e.g.
    # "conversions.conversion_recorded" -> "conversions". Used for graph edges.
    def module_name(topic)
      topic.to_s.split(".", 2).first
    end
  end
end

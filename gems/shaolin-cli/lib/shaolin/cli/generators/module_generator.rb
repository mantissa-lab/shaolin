require "thor"
require "thor/group"
require_relative "../naming"

module Shaolin
  module CLI
    module Generators
      # Scaffolds a complete CQRS/ES module (mirrors examples/demo's `users`):
      # command, event, aggregate, command handler, projection, read model, DTO,
      # controller, read-model migration, and CONTRACT.md. The result boots and
      # serves immediately; customize from there.
      class ModuleGenerator < Thor::Group
        include Thor::Actions

        argument :name, type: :string, desc: "module name (plural, e.g. users)"

        def self.source_root
          File.expand_path("../templates/module", __dir__)
        end

        def set_variables
          @name       = Naming.module_us(name)
          @ns         = Naming.namespace(name)
          @entity     = Naming.entity(name)
          @entity_us  = Naming.entity_us(name)
          @command    = Naming.command(name)
          @command_us = Naming.command_us(name)
          @event      = Naming.event(name)
          @event_us   = Naming.event_us(name)
          @topic      = Naming.topic(name)
          @read_table = Naming.read_table(name)
        end

        def create_module
          base = "app/modules/#{@name}"
          template "module.rb.erb",          "#{base}/module.rb"
          template "command.rb.erb",         "#{base}/commands/#{@command_us}.rb"
          template "event.rb.erb",           "#{base}/events/#{@event_us}.rb"
          template "aggregate.rb.erb",       "#{base}/#{@entity_us}.rb"
          template "command_handler.rb.erb", "#{base}/command_handlers/#{@command_us}_handler.rb"
          template "read_model.rb.erb",      "#{base}/read_models/#{@entity_us}_record.rb"
          template "projection.rb.erb",      "#{base}/projections/#{@name}_projection.rb"
          template "dto.rb.erb",             "#{base}/dto/#{@command_us}_dto.rb"
          template "controller.rb.erb",      "#{base}/controllers/#{@name}_controller.rb"
          template "migration.rb.erb",       "#{base}/db/migrate/#{migration_timestamp}_create_#{@name}_read.rb"
          template "CONTRACT.md.erb",        "#{base}/CONTRACT.md"
        end

        private

        def migration_timestamp
          @migration_timestamp ||= Time.now.strftime("%Y%m%d%H%M%S")
        end
      end
    end
  end
end

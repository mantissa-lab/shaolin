require "thor"
require "thor/group"
require_relative "../naming"

module Shaolin
  module CLI
    module Generators
      # Adds a field to a module: generates the add_column migration (the safe,
      # mechanical, version-bumped part) and prints the remaining edit checklist.
      # We deliberately do NOT rewrite existing Ruby (command/event/aggregate/
      # projection/DTO) — that's fragile; the checklist points at exactly what to
      # touch. Targets the read-model table for ES modules, the table for CRUD.
      class FieldGenerator < Thor::Group
        include Thor::Actions

        argument :module_name, type: :string, desc: "module (plural, e.g. orders)"
        argument :field_spec, type: :string, desc: "name:type (e.g. amount:integer)"

        def self.source_root = File.expand_path("../templates", __dir__)

        def set_variables
          @module     = Naming.module_us(module_name)
          @entity_us  = Naming.entity_us(module_name)
          @command_us = Naming.command_us(module_name)
          @field, type = field_spec.split(":", 2)
          @type = (type && !type.empty?) ? type : "string"
          @es = Dir.exist?(File.join(destination_root, "app/modules/#{@module}/events"))
          @table = @es ? Naming.read_table(module_name) : @module
          @migration_class = Naming.migration_class("add_#{@field}_to_#{@table}")
        end

        def create_migration
          template "field/add_column.rb.erb",
                   "app/modules/#{@module}/db/migrate/#{migration_timestamp}_add_#{@field}_to_#{@table}.rb"
        end

        def checklist
          say "\nMigration added. Also update (by hand — kept explicit, not auto-edited):", :yellow
          base = "app/modules/#{@module}"
          if @es
            say "  - #{base}/commands/#{@command_us}.rb            (attribute)"
            say "  - #{base}/events/#{@entity_us}_created.rb        (event data)"
            say "  - #{base}/dto/#{@command_us}_dto.rb              (validation rule)"
            say "  - #{base}/#{@entity_us}.rb                       (apply in the aggregate)"
            say "  - #{base}/projections/*_projection.rb           (write to the read model)"
          else
            say "  - #{base}/dto/#{@entity_us}_dto.rb               (validation rule)"
            say "  - #{base}/controllers/#{@module}_controller.rb   (permit/pass the field)"
          end
        end

        private

        def migration_timestamp
          @migration_timestamp ||= begin
            version = Time.now.strftime("%Y%m%d%H%M%S").to_i
            existing = Dir.glob(File.join(destination_root, "app/modules/*/db/migrate/*.rb"))
                          .map { |f| File.basename(f)[/\A\d+/].to_i }
            version += 1 while existing.include?(version)
            version.to_s
          end
        end
      end
    end
  end
end

require "thor"
require "thor/group"
require_relative "../naming"

module Shaolin
  module CLI
    module Generators
      # Scaffolds a module. Default is a full CQRS/ES module (mirrors
      # examples/demo's `users`): command, event, aggregate, handler, projection,
      # read model, DTO, controller, migration, CONTRACT. With `--crud` it
      # scaffolds a plain ActiveRecord CRUD module (no event sourcing). Either
      # boots and serves immediately.
      class ModuleGenerator < Thor::Group
        include Thor::Actions

        argument :name, type: :string, desc: "module name (plural, e.g. users)"
        class_option :crud, type: :boolean, default: false,
                            desc: "plain CRUD module (ActiveRecord, no event sourcing)"
        class_option :reactor, type: :boolean, default: false,
                            desc: "also scaffold an async Reactor (outbox side effect) + spec"

        def self.source_root
          File.expand_path("../templates", __dir__)
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
          @table      = @name
          # Migration class names must match ActiveRecord's filename->constant rule.
          @migration_class      = Naming.migration_class("create_#{@name}_read")
          @crud_migration_class = Naming.migration_class("create_#{@name}")
        end

        def create_module
          if options[:crud] && options[:reactor]
            raise Thor::Error, "--reactor needs events; it can't combine with --crud (a CRUD module has none)"
          end

          options[:crud] ? create_crud_module : create_cqrs_module
          create_reactor if options[:reactor]
        end

        private

        def create_reactor
          base = "app/modules/#{@name}"
          template "module/reactor.rb.erb",      "#{base}/reactors/#{@entity_us}_reactor.rb"
          template "module/reactor_spec.rb.erb", "spec/reactors/#{@entity_us}_reactor_spec.rb"
        end

        def create_crud_module
          base = "app/modules/#{@name}"
          template "crud/module.rb.erb",     "#{base}/module.rb"
          template "crud/model.rb.erb",      "#{base}/#{@entity_us}.rb"
          template "crud/dto.rb.erb",        "#{base}/dto/#{@entity_us}_dto.rb"
          template "crud/controller.rb.erb", "#{base}/controllers/#{@name}_controller.rb"
          template "crud/migration.rb.erb",  "#{base}/db/migrate/#{migration_timestamp}_create_#{@name}.rb"
          template "crud/CONTRACT.md.erb",   "#{base}/CONTRACT.md"
          template "crud/request_spec.rb.erb", "spec/requests/#{@name}_spec.rb"
        end

        def create_cqrs_module
          base = "app/modules/#{@name}"
          template "module/module.rb.erb",          "#{base}/module.rb"
          template "module/command.rb.erb",         "#{base}/commands/#{@command_us}.rb"
          template "module/event.rb.erb",           "#{base}/events/#{@event_us}.rb"
          template "module/aggregate.rb.erb",        "#{base}/#{@entity_us}.rb"
          template "module/command_handler.rb.erb",  "#{base}/command_handlers/#{@command_us}_handler.rb"
          template "module/read_model.rb.erb",       "#{base}/read_models/#{@entity_us}_record.rb"
          template "module/projection.rb.erb",       "#{base}/projections/#{@name}_projection.rb"
          template "module/query.rb.erb",            "#{base}/queries/find_#{@entity_us}.rb"
          template "module/query_handler.rb.erb",    "#{base}/query_handlers/find_#{@entity_us}_handler.rb"
          template "module/dto.rb.erb",              "#{base}/dto/#{@command_us}_dto.rb"
          template "module/controller.rb.erb",       "#{base}/controllers/#{@name}_controller.rb"
          template "module/migration.rb.erb",        "#{base}/db/migrate/#{migration_timestamp}_create_#{@name}_read.rb"
          template "module/CONTRACT.md.erb",         "#{base}/CONTRACT.md"
          template "module/aggregate_spec.rb.erb",   "spec/#{@entity_us}_spec.rb"
          template "module/request_spec.rb.erb",     "spec/requests/#{@name}_spec.rb"
        end

        # A unique migration version: the current timestamp, bumped past any
        # existing migration in the app so two modules generated in the same
        # second don't collide (ActiveRecord requires unique versions).
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

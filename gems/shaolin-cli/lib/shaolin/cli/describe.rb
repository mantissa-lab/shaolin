require "shaolin/core"
require_relative "static_scan"

module Shaolin
  module CLI
    # Builds a machine-readable map of an app from its module manifests (no boot,
    # no DB). Powers `shaolin describe --json` so an agent can understand the
    # whole system in one call. HTTP routes need the booted app — see `shaolin
    # routes` — so this map is manifest-level (commands/events/imports/exports).
    module Describe
      module_function

      def map(modules_dir)
        Shaolin::Registry.reset!
        Dir.glob(File.join(modules_dir, "*", "module.rb")).sort.each { |file| require file }
        app_root = File.expand_path("..", modules_dir) # app/modules -> app

        {
          ruby: RUBY_VERSION,
          modules: Shaolin::Registry.all.map { |mod| module_map(mod, modules_dir) },
          scheduled: StaticScan.schedules(app_root, File.join(File.expand_path("..", app_root), "config"))
        }
      end

      def module_map(mod, modules_dir)
        {
          name: mod.name,
          imports: mod.imports,
          exports: mod.exports,
          commands_handled: mod.commands_handled,
          events_published: mod.events_published,
          events_subscribed: mod.subscribed_events,
          reactors: StaticScan.reactors(File.join(modules_dir, mod.name))
        }
      end

      # Just the command/event surface, for `shaolin schemas`.
      def schemas(modules_dir)
        map(modules_dir)[:modules].map do |m|
          { name: m[:name], commands: m[:commands_handled], events: m[:events_published] }
        end
      end
    end
  end
end

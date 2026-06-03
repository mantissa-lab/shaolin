require "thor"
require_relative "generators/module_generator"
require_relative "generators/new_app_generator"

module Shaolin
  module CLI
    # The `shaolin` executable.
    class Main < Thor
      def self.exit_on_failure? = true

      desc "new APP", "Scaffold a new shaolin application"
      method_option :path, type: :string, desc: "path to a local shaolin checkout (Gemfile uses path: gems)"
      def new(app)
        opts = options[:path] ? { "path" => options[:path] } : {}
        Generators::NewAppGenerator.new([app], opts).invoke_all
      end

      desc "generate TYPE NAME", "Generate code (TYPE: module). --crud for a plain CRUD module"
      map "g" => :generate
      method_option :crud, type: :boolean, default: false, desc: "plain CRUD module (no event sourcing)"
      def generate(type, name)
        case type
        when "module"
          gen = Generators::ModuleGenerator.new([name], { "crud" => options[:crud] })
          gen.destination_root = Dir.pwd
          gen.invoke_all
        else
          raise Thor::Error, "unknown generator #{type.inspect} (available: module)"
        end
      end

      desc "server", "Boot the app and serve HTTP (Falcon by default)"
      def server
        boot_app!
        require "shaolin/server"
        Shaolin::Server.run(Shaolin::Kernel["http.app"])
      end

      desc "console", "Boot the app and open an IRB console"
      def console
        boot_app!
        require "irb"
        IRB.start
      end

      desc "migrate", "Boot the app, ensuring event store + read-model schemas"
      def migrate
        boot_app!
        say "schema up to date", :green
      end

      desc "projections ACTION [NAME]", "Projection tasks. ACTION: rebuild (replay events into read models)"
      def projections(action, name = nil)
        raise Thor::Error, "unknown action #{action.inspect} (available: rebuild)" unless action == "rebuild"

        boot_app!
        require "shaolin/cqrs"
        Shaolin::CQRS::ProjectionRunner.rebuild_all(only: name)
        say "projections rebuilt#{name ? " for #{name}" : ""}", :green
      end

      desc "describe", "Print a machine-readable map of the app (modules, commands, events, imports)"
      method_option :json, type: :boolean, default: false, desc: "emit JSON (for agents/tools)"
      def describe
        require_relative "describe"
        data = Describe.map(File.join(Dir.pwd, "app/modules"))
        if options[:json]
          require "json"
          puts JSON.pretty_generate(data)
        else
          data[:modules].each do |m|
            say m[:name], :cyan
            m[:commands_handled].each  { |c| say "  command: #{c}" }
            m[:events_published].each  { |e| say "  event:   #{e}" }
            m[:imports].each           { |i| say "  import:  #{i}" }
            m[:exports].each           { |x| say "  export:  #{x}" }
          end
        end
      end

      desc "schemas", "Print each module's command/event surface"
      method_option :json, type: :boolean, default: false
      def schemas
        require_relative "describe"
        require "json"
        puts JSON.pretty_generate(Describe.schemas(File.join(Dir.pwd, "app/modules")))
      end

      desc "lint", "Check module isolation (no cross-module reach-ins) — Prism static analysis"
      def lint
        require_relative "isolation"
        modules_dir = File.join(Dir.pwd, "app/modules")
        raise Thor::Error, "no app/modules in #{Dir.pwd}" unless File.directory?(modules_dir)

        violations = Isolation.new(modules_dir).violations
        if violations.empty?
          say "isolation OK — modules are self-contained", :green
        else
          violations.each { |v| say v.to_s, :red }
          raise Thor::Error, "#{violations.size} isolation violation(s)"
        end
      end

      desc "graph", "Print the module dependency graph (imports + events) from manifests"
      def graph
        require "shaolin/core"
        Shaolin::Registry.reset!
        Dir.glob(File.join(Dir.pwd, "app/modules", "*", "module.rb")).sort.each { |f| require f }
        Shaolin::Registry.all.each do |mod|
          say mod.name, :cyan
          mod.imports.each          { |i| say "  imports:    #{i}" }
          mod.events_published.each { |e| say "  publishes:  #{e}" }
          mod.subscribed_events.each { |e| say "  subscribes: #{e}" }
        end
      end

      desc "routes", "List modules and the commands/events they expose"
      def routes
        boot_app!
        Shaolin::Registry.all.each do |mod|
          say mod.name, :cyan
          mod.commands_handled.each { |c| say "  command: #{c}" }
          mod.events_published.each { |e| say "  event:   #{e}" }
        end
      end

      private

      def boot_app!
        boot = File.expand_path("config/boot.rb", Dir.pwd)
        raise Thor::Error, "not a shaolin app (no config/boot.rb in #{Dir.pwd})" unless File.exist?(boot)

        require boot
      end
    end
  end
end

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

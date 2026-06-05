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

      desc "generate TYPE NAME", "Generate code (TYPE: module). --crud for a plain CRUD module; --reactor adds an async reactor"
      map "g" => :generate
      method_option :crud, type: :boolean, default: false, desc: "plain CRUD module (no event sourcing)"
      method_option :reactor, type: :boolean, default: false, desc: "also scaffold an async reactor + spec"
      def generate(type, name)
        case type
        when "module"
          gen = Generators::ModuleGenerator.new([name], { "crud" => options[:crud], "reactor" => options[:reactor] })
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
        # Falcon is fiber-per-request, so AR connections must be isolated per
        # fiber (otherwise concurrent fibers share one connection). The worker
        # process stays thread-isolated. Set it here, matching the runtime.
        if defined?(Shaolin::AR) && Shaolin::Server::Config.new.adapter == :falcon
          Shaolin::AR::Connection.isolation_level = :fiber
        end
        Shaolin::Server.run(Shaolin::Kernel["http.app"])
      end

      desc "console", "Boot the app and open an IRB console"
      def console
        boot_app!
        require "irb"
        IRB.start
      end

      desc "migrate", "Apply schema (event store + jobs) and run read-model migrations — the release step"
      def migrate
        boot_app!
        apply_schema!
        say "schema up to date", :green
      end

      desc "db ACTION", "Database tasks. ACTION: reset (drop + create + migrate — DEV ONLY)"
      def db(action = "reset")
        raise Thor::Error, "unknown db action #{action.inspect} (available: reset)" unless action == "reset"
        raise Thor::Error, "refusing to db reset with SHAOLIN_ENV=production" if ENV["SHAOLIN_ENV"] == "production"

        boot_app!
        require "shaolin/activerecord"
        cfg = ::ActiveRecord::Base.connection_db_config.configuration_hash
        name = cfg[:database]
        recreate_database!(cfg, name)
        ::ActiveRecord::Base.establish_connection(cfg)
        apply_schema!
        say "db reset: dropped + recreated + migrated #{name}", :green
      end

      desc "rollback [STEPS]", "Roll back the last STEPS read-model migrations (default 1)"
      def rollback(steps = "1")
        boot_app!
        require "shaolin/activerecord"
        Shaolin::AR::Migrator.rollback(File.join(Dir.pwd, "app/modules"), Integer(steps))
        say "rolled back #{steps} migration(s)", :green
      end

      desc "worker", "Run the jobs worker — process the outbox (async reactors)"
      def worker
        boot_app!
        require "shaolin/jobs"
        threads = Integer(ENV.fetch("WORKER_CONCURRENCY", "1"))
        batch = Integer(ENV.fetch("WORKER_BATCH", "20"))
        tx_per_job = %w[1 true].include?(ENV["WORKER_TX_PER_JOB"])
        pool = ::ActiveRecord::Base.connection_pool.size
        if threads > pool
          say "warning: WORKER_CONCURRENCY=#{threads} exceeds DB pool=#{pool}; set DB_POOL>=#{threads} to avoid connection timeouts", :yellow
        end
        mode = tx_per_job ? "tx-per-job (IO-bound)" : "batch-tx"
        say "shaolin worker started (#{threads} thread(s), batch #{batch}, #{mode}, DB pool #{pool})", :green
        Shaolin::Jobs::Worker.new(
          event_store: Shaolin::Kernel["cqrs.event_store"], batch: batch, tx_per_job: tx_per_job
        ).run(threads: threads)
      end

      desc "scheduler", "Run the scheduler — fire periodic tasks (single leader via advisory lock)"
      def scheduler
        boot_app!
        require "shaolin/jobs"
        say "shaolin scheduler started", :green
        Shaolin::Jobs::Scheduler.new.run
      end

      desc "jobs [ACTION] [ID]", "Inspect the outbox — ACTION: stats (default), dead, retry ID"
      def jobs(action = "stats", id = nil)
        boot_app!
        require "shaolin/jobs"
        outbox = Shaolin::Jobs::Outbox.new
        case action
        when "stats"
          counts = outbox.stats
          %w[pending failed done dead].each { |s| say format("  %-8s %d", s, counts.fetch(s, 0)) }
        when "dead"
          dead = outbox.dead
          say "no dead-lettered jobs", :green if dead.empty?
          dead.each { |j| say "#{j.id}\t#{j.reactor}\t#{j.event_type}\t#{j.last_error}", :red }
        when "retry"
          raise Thor::Error, "usage: shaolin jobs retry ID" unless id

          done = outbox.retry!(id).to_i.positive?
          say(done ? "re-queued job #{id}" : "no dead job #{id}", done ? :green : :yellow)
        else
          raise Thor::Error, "unknown action #{action.inspect} (stats | dead | retry ID)"
        end
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
            m[:events_subscribed].each { |e| say "  subscribes: #{e} (from #{e.split('.').first})" }
            (m[:reactors] || []).each do |r|
              subs = (r[:on] + (r[:topics] || [])).join(", ")
              say "  reactor: #{r[:class]} on #{subs}"
            end
          end
          (data[:scheduled] || []).each { |s| say "scheduled: #{s[:name]} every #{s[:every]}", :magenta }
          (data[:harnesses] || []).each do |h|
            say "harness: #{h[:name]} (llm #{h[:model]})", :magenta
            h[:gates].each do |g|
              flags = [("entry" if g[:entry]), ("terminal" if g[:terminal])].compact.join(",")
              edges = (g[:to] || []).empty? ? "" : " -> #{g[:to].join(', ')}"
              say "  gate: #{g[:name]}#{" [#{flags}]" unless flags.empty?} tools=#{g[:tools]}#{edges}"
            end
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
          # a subscribed topic is an edge to its owning module: B -> A
          mod.subscribed_events.each { |e| say "  #{mod.name} -> #{Shaolin::Topic.module_name(e)}  (consumes #{e})" }
        end

        require_relative "describe"
        Describe.harnesses(File.join(Dir.pwd, "app")).each do |h|
          say "harness #{h[:name]}", :magenta
          h[:gates].each do |g|
            (g[:to] || []).each { |to| say "  #{g[:name]} -> #{to}" }
            say "  #{g[:name]} (terminal)" if g[:terminal] && (g[:to] || []).empty?
          end
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

      def apply_schema!
        require "shaolin/activerecord"
        Shaolin::AR::EventStoreSchema.create!
        Shaolin::AR::Migrator.run(File.join(Dir.pwd, "app/modules"))
        Shaolin::Jobs::Schema.create! if defined?(Shaolin::Jobs::Schema)
      end

      # Drop + recreate the database via a maintenance connection (postgres db),
      # FORCE-terminating any open connections. Dev only.
      def recreate_database!(cfg, name)
        ::ActiveRecord::Base.connection_handler.clear_all_connections!
        ::ActiveRecord::Base.establish_connection(cfg.merge(database: "postgres"))
        conn = ::ActiveRecord::Base.connection
        conn.execute(%(DROP DATABASE IF EXISTS "#{name}" WITH (FORCE)))
        conn.execute(%(CREATE DATABASE "#{name}"))
        ::ActiveRecord::Base.connection_handler.clear_all_connections!
      end
    end
  end
end

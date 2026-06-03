require "thor"
require "thor/group"
require_relative "../naming"

module Shaolin
  module CLI
    module Generators
      # Scaffolds a runnable shaolin application: Gemfile, boot, server entry,
      # Dockerfile, Knative deploy manifest, AGENTS.md, and an empty modules dir.
      class NewAppGenerator < Thor::Group
        include Thor::Actions

        argument :name, type: :string, desc: "application name"
        class_option :path, type: :string, default: nil,
                            desc: "path to a local shaolin checkout (Gemfile uses path: gems)"

        def self.source_root
          File.expand_path("../templates/app", __dir__)
        end

        def set_variables
          @app = Naming.module_us(name)
          @app_class = Naming.namespace(name)
          @local_path = options[:path] && File.expand_path(options[:path])
        end

        def create_app
          template(@local_path ? "Gemfile.local.erb" : "Gemfile.erb", "#{@app}/Gemfile")
          template "config/boot.rb.erb",     "#{@app}/config/boot.rb"
          template "bin/server.erb",         "#{@app}/bin/server"
          template "Dockerfile.erb",         "#{@app}/Dockerfile"
          template "AGENTS.md.erb",          "#{@app}/AGENTS.md"
          template "README.md.erb",          "#{@app}/README.md"
          template "deploy/service.yaml.erb", "#{@app}/deploy/service.yaml"
          template "env.example",            "#{@app}/.env.example"
          copy_file "dockerignore",          "#{@app}/.dockerignore"
          copy_file "rspec",                 "#{@app}/.rspec"
          template "spec/spec_helper.rb.erb", "#{@app}/spec/spec_helper.rb"
          create_file "#{@app}/.ruby-version", "4.0.5\n"
          create_file "#{@app}/app/modules/.keep", ""
          chmod "#{@app}/bin/server", 0o755
        end
      end
    end
  end
end

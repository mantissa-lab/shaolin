require_relative "registry"
require_relative "container_builder"
require_relative "module_container"
require_relative "provider"

module Shaolin
  # Orchestrates the boot phases: discover module manifests, build a container
  # per module, start providers in dependency order, then wire imports/exports
  # with isolation enforcement.
  class Lifecycle
    attr_reader :containers

    def initialize(root:, config:)
      @root = root
      @config = config
      @containers = {}
    end

    def boot!
      discover
      register_containers
      expose_containers
      Provider.start_all
      wire
      self
    end

    def shutdown! = Provider.stop_all

    private

    def modules_dir = File.join(@root, @config.modules_path)

    def discover
      Dir.glob(File.join(modules_dir, "*", "module.rb")).sort.each { |file| require file }
    end

    def register_containers
      Registry.all.each do |defn|
        dir = File.join(modules_dir, defn.name)
        ds = ContainerBuilder.build(name: defn.name, dir: dir)
        @containers[defn.name] = ModuleContainer.new(definition: defn, container: ds)
      end
    end

    # Expose the module containers to providers (e.g. :http enumerates
    # controllers) via the shared kernel, before providers start.
    def expose_containers
      containers = @containers
      Kernel.register("kernel.containers") { containers }
    end

    def wire
      Registry.all.each do |defn|
        consumer = @containers[defn.name]
        wire_imports(defn, consumer)
        validate_exports(defn, consumer)
      end
    end

    def wire_imports(defn, consumer)
      defn.imports.each do |key|
        owner_name, export_key = key.split(".", 2)
        owner = @containers[owner_name]
        unless owner
          raise ManifestError.new("imports unknown module '#{owner_name}'", module_name: defn.name)
        end
        unless owner.exports?(export_key)
          raise IsolationError.new(consumer: defn.name, key: key, owner: owner_name)
        end

        consumer.register_import(key) { owner[export_key] }
      end
    end

    def validate_exports(defn, consumer)
      defn.exports.each do |export_key|
        next if consumer.key?(export_key)

        raise ManifestError.new(
          "exports '#{export_key}' which is not a registered component",
          module_name: defn.name
        )
      end
    end
  end
end

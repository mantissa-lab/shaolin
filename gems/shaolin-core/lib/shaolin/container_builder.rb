require "dry/system"
require "dry/inflector"

module Shaolin
  # Builds an isolated dry-system container rooted at a single module's folder.
  # Components auto-register by file/dir convention: `user_service.rb` ->
  # key "user_service" (const `<Module>::UserService`); `queries/find_user.rb`
  # -> key "queries.find_user" (const `<Module>::Queries::FindUser`). Zeitwerk
  # autoloads components by constant, so module code needs no `require_relative`.
  module ContainerBuilder
    def self.build(name:, dir:)
      const_ns = name.to_s
      klass = Class.new(Dry::System::Container)
      klass.use(:zeitwerk)
      klass.configure do |config|
        config.name = name.to_sym
        config.root = dir
        config.inflector = inflector
        config.component_dirs.add "." do |component_dir|
          component_dir.namespaces.add_root(const: const_ns)
        end
      end
      klass.finalize!
      klass
    end

    # The shared shaolin inflector (single source of truth, see Shaolin::Inflector).
    def self.inflector = Shaolin::Inflector.instance
  end
end

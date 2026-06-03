require "dry/system"
require "dry/inflector"

module Shaolin
  # Builds an isolated dry-system container rooted at a single module's folder.
  # Components auto-register by file/dir convention: `user_service.rb` ->
  # key "user_service" (const `<Module>::UserService`); `queries/find_user.rb`
  # -> key "queries.find_user" (const `<Module>::Queries::FindUser`). Zeitwerk
  # autoloads components by constant, so module code needs no `require_relative`.
  module ContainerBuilder
    # Acronyms the autoloader/inflector must respect (e.g. `dto/` -> `DTO`).
    ACRONYMS = %w[DTO ID API HTTP URL UUID].freeze

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

    def self.inflector
      Dry::Inflector.new do |i|
        ACRONYMS.each { |a| i.acronym(a) }
      end
    end
  end
end

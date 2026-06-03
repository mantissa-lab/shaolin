require "dry/system"

module Shaolin
  # Builds an isolated dry-system container rooted at a single module's folder.
  # Components auto-register by file/dir convention: `user_service.rb` ->
  # key "user_service" (const `<Module>::UserService`); `queries/find_user.rb`
  # -> key "queries.find_user" (const `<Module>::Queries::FindUser`).
  module ContainerBuilder
    def self.build(name:, dir:)
      const_ns = name.to_s
      klass = Class.new(Dry::System::Container)
      klass.configure do |config|
        config.name = name.to_sym
        config.root = dir
        config.component_dirs.add "." do |component_dir|
          component_dir.namespaces.add_root(const: const_ns)
        end
      end
      klass.finalize!
      klass
    end
  end
end

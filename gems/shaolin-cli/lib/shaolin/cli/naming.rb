require "shaolin/core"

module Shaolin
  module CLI
    # Single source of inflection conventions, so generated names match the
    # kernel's container-key conventions and the proven demo layout. Uses THE
    # shared Shaolin::Inflector (acronym-aware) so generator names and the zeitwerk
    # autoloader agree (e.g. url_maps -> URLMaps in both).
    module Naming
      INFLECTOR = Shaolin::Inflector.instance

      module_function

      def namespace(name)  = INFLECTOR.camelize(INFLECTOR.underscore(name)) # "users" -> "Users"
      def entity(name)     = INFLECTOR.camelize(INFLECTOR.singularize(INFLECTOR.underscore(name))) # "users" -> "User"
      def entity_us(name)  = INFLECTOR.underscore(entity(name)) # "users" -> "user"
      def module_us(name)  = INFLECTOR.underscore(name) # "Users" -> "users"
      def read_table(name) = "#{module_us(name)}_read"
      def command(name)    = "Create#{entity(name)}"     # -> "CreateUser"
      def command_us(name) = INFLECTOR.underscore(command(name)) # -> "create_user"
      def event(name)      = "#{entity(name)}Created"    # -> "UserCreated"
      def event_us(name)   = INFLECTOR.underscore(event(name)) # -> "user_created"
      def topic(name)      = "#{module_us(name)}.#{event_us(name)}" # -> "users.user_created"

      # The migration class name MUST match what ActiveRecord's MigrationContext
      # derives from the filename (ActiveSupport camelize, NO acronyms) — not the
      # dry-inflector namespace, which uppercases acronyms (api_keys -> APIKeys)
      # and would yield CreateAPIKeysRead while AR looks for CreateApiKeysRead.
      # Plain segment-capitalize matches AR's default for snake_case stems.
      def migration_class(stem) = stem.split("_").map(&:capitalize).join
    end
  end
end

require "dry/inflector"

module Shaolin
  module CLI
    # Single source of inflection conventions, so generated names match the
    # kernel's container-key conventions and the proven demo layout.
    module Naming
      INFLECTOR = Dry::Inflector.new

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
    end
  end
end

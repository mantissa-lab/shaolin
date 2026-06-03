require "shaolin/cqrs"
require "dry/monads"
require_relative "../user"
require_relative "../commands/register_user"

module Users
  module CommandHandlers
    class RegisterUserHandler < Shaolin::CQRS::CommandHandler
      include Dry::Monads[:result]

      handles Commands::RegisterUser

      def call(cmd)
        aggregate_repository.unit_of_work(User.new(cmd.id)) do |user|
          user.register(name: cmd.name, email: cmd.email)
        end
        Success(cmd.id)
      end
    end
  end
end

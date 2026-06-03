require "shaolin/core"

module Shaolin
  module CQRS
    # Base for command handlers. Declare which command it handles with `handles`;
    # the :cqrs provider auto-registers it on the command bus at boot. The
    # aggregate repository and event store are resolved lazily from the kernel.
    #
    #   class RegisterUserHandler < Shaolin::CQRS::CommandHandler
    #     handles RegisterUser
    #     def call(cmd)
    #       aggregate_repository.unit_of_work(User.new(cmd.id)) { |u| u.register(email: cmd.email) }
    #       Dry::Monads::Success(cmd.id)
    #     end
    #   end
    class CommandHandler
      def self.handles(command_class) = (@handled_command = command_class)
      def self.handled_command = @handled_command

      def aggregate_repository = Shaolin::Kernel["cqrs.aggregate_repository"]
      def event_store = Shaolin::Kernel["cqrs.event_store"]
    end
  end
end

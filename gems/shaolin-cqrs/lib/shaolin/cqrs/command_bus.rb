require "shaolin/core"
require "arkency/command_bus"

module Shaolin
  module CQRS
    # Raised when a command is dispatched with no registered handler.
    class UnregisteredCommand < Shaolin::Error; end

    # Routes a command to its single handler. Wraps Arkency::CommandBus for
    # dispatch while tracking registrations so a missing handler fails with a
    # clear, machine-readable error rather than a library-internal one.
    class CommandBus
      def initialize
        @bus = Arkency::CommandBus.new
        @handlers = {}
      end

      # handler is any callable responding to #call(command).
      def register(command_class, handler)
        @handlers[command_class] = handler
        @bus.register(command_class, ->(cmd) { handler.call(cmd) })
        self
      end

      def call(command)
        unless @handlers.key?(command.class)
          raise UnregisteredCommand, "no handler registered for #{command.class}"
        end

        @bus.call(command)
      end

      def registered?(command_class) = @handlers.key?(command_class)
    end
  end
end

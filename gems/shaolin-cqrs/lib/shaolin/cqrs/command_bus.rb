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

        return @bus.call(command) unless Shaolin::Log.everything?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          result = @bus.call(command)
          Shaolin::Log.info("command", command: command.class.name,
                                       duration_ms: ms_since(started))
          result
        rescue StandardError => e
          Shaolin::Log.error("command_failed", command: command.class.name, error: e.message)
          raise
        end
      end

      def registered?(command_class) = @handlers.key?(command_class)

      private

      def ms_since(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    end
  end
end

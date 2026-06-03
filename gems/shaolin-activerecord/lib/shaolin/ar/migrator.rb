require "active_record"

module Shaolin
  module AR
    # Runs per-module read-model migrations found under
    # `app/modules/*/db/migrate/`. Each module keeps its own migrations so a
    # module stays self-contained and agent-ownable.
    module Migrator
      def self.run(modules_dir)
        context = context_for(modules_dir)
        return unless context

        ::ActiveRecord::Migration.suppress_messages { context.migrate }
      end

      # Roll back the last `steps` applied migrations (across all modules).
      def self.rollback(modules_dir, steps = 1)
        context = context_for(modules_dir)
        return unless context

        ::ActiveRecord::Migration.suppress_messages { context.rollback(steps) }
      end

      def self.context_for(modules_dir)
        paths = Dir.glob(File.join(modules_dir, "*", "db", "migrate")).select { |d| Dir.exist?(d) }.sort
        return nil if paths.empty?

        ::ActiveRecord::MigrationContext.new(paths)
      end
    end
  end
end

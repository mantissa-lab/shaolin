require "active_record"

module Shaolin
  module AR
    # Runs per-module read-model migrations found under
    # `app/modules/*/db/migrate/`. Each module keeps its own migrations so a
    # module stays self-contained and agent-ownable.
    module Migrator
      def self.run(modules_dir)
        paths = Dir.glob(File.join(modules_dir, "*", "db", "migrate")).select { |d| Dir.exist?(d) }.sort
        return if paths.empty?

        context = ::ActiveRecord::MigrationContext.new(paths)
        ::ActiveRecord::Migration.suppress_messages { context.migrate }
      end
    end
  end
end

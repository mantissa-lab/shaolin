require "active_record"
require "digest"
require "shaolin/core"

module Shaolin
  module AR
    # Runs per-module read-model migrations found under
    # `app/modules/*/db/migrate/`. Each module keeps its own migrations so a
    # module stays self-contained and agent-ownable.
    #
    # Drift detection (Flyway/Rails-style): the checksum of every applied
    # migration file is stored in `shaolin_migration_checksums`. If an already
    # applied migration's file later changes on disk, `run` raises BEFORE
    # migrating — turning a silent prod divergence (file edited, but the version
    # is in `schema_migrations`, so the change never reaches a persistent DB
    # while a fresh dev DB / `shaolin db reset` hides it) into an immediate,
    # actionable error. New (unapplied) files are free to change.
    module Migrator
      CHECKSUM_TABLE = "shaolin_migration_checksums".freeze

      def self.run(modules_dir)
        context = context_for(modules_dir)
        return unless context

        files = migration_files(modules_dir)
        ensure_checksum_table!
        check_drift!(files)
        ::ActiveRecord::Migration.suppress_messages { context.migrate }
        record_checksums!(files)
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

      # --- drift detection -------------------------------------------------

      # Raise if any migration that is ALREADY applied has a file whose checksum
      # no longer matches what was recorded when it was first applied.
      def self.check_drift!(files)
        applied = applied_versions
        stored = stored_checksums
        drifted = files.filter_map do |file|
          version = version_of(file)
          next unless version && applied.include?(version) && stored.key?(version)

          basename = File.basename(file) if checksum(file) != stored[version]
          basename
        end
        return if drifted.empty?

        raise Shaolin::Error, <<~MSG.chomp
          migration drift detected — these applied migrations changed on disk:
            #{drifted.join("\n  ")}
          An applied migration must never be edited: the change won't reach a
          database where the version is already in schema_migrations.
            dev:  `shaolin db reset` (re-applies from scratch), then re-edit freely
            prod: revert the edit and add a NEW migration for the change
        MSG
      end

      def self.migration_files(modules_dir)
        Dir.glob(File.join(modules_dir, "*", "db", "migrate", "*.rb")).sort
      end

      def self.version_of(file)
        m = File.basename(file)[/\A(\d+)_/, 1]
        m
      end

      def self.checksum(file)
        Digest::SHA256.hexdigest(File.read(file))
      end

      def self.applied_versions
        conn = ::ActiveRecord::Base.connection
        return [] unless conn.table_exists?("schema_migrations")

        conn.select_values("SELECT version FROM schema_migrations").map(&:to_s)
      end

      def self.stored_checksums
        conn = ::ActiveRecord::Base.connection
        conn.select_rows("SELECT version, checksum FROM #{CHECKSUM_TABLE}").to_h
      end

      # Record the current checksum for every migration file the FIRST time we
      # see its version (ON CONFLICT DO NOTHING). This blesses the current
      # content of freshly applied migrations — and, on the first run after this
      # feature ships, the current content of pre-existing ones — so subsequent
      # edits to an applied migration are caught. It never overwrites an existing
      # checksum, which is exactly what makes a later edit detectable.
      def self.record_checksums!(files)
        conn = ::ActiveRecord::Base.connection
        files.each do |file|
          version = version_of(file)
          next unless version

          conn.execute(
            "INSERT INTO #{CHECKSUM_TABLE} (version, checksum) " \
            "VALUES (#{conn.quote(version)}, #{conn.quote(checksum(file))}) " \
            "ON CONFLICT (version) DO NOTHING"
          )
        end
      end

      def self.ensure_checksum_table!
        conn = ::ActiveRecord::Base.connection
        return if conn.table_exists?(CHECKSUM_TABLE)

        conn.create_table(CHECKSUM_TABLE, id: false) do |t|
          t.string :version, null: false
          t.string :checksum, null: false
        end
        conn.add_index(CHECKSUM_TABLE, :version, unique: true)
      end
    end
  end
end

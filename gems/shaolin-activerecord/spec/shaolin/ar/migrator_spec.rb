require "shaolin/activerecord"
require "support/pg"
require "tmpdir"
require "fileutils"

RSpec.describe Shaolin::AR::Migrator do
  before { PgTest.reset_schema! }

  it "runs per-module read-model migrations" do
    Dir.mktmpdir do |root|
      migrate_dir = File.join(root, "app/modules/widgets/db/migrate")
      FileUtils.mkdir_p(migrate_dir)
      File.write(File.join(migrate_dir, "20260603000001_create_widgets_read.rb"), <<~RUBY)
        class CreateWidgetsRead < ActiveRecord::Migration[8.0]
          def change
            create_table(:widgets_read, id: false) do |t|
              t.string :id, null: false
              t.string :name
            end
          end
        end
      RUBY

      described_class.run(File.join(root, "app/modules"))
      expect(ActiveRecord::Base.connection.table_exists?("widgets_read")).to be(true)
    end
  end

  # A migration file is the source of truth ONLY until it is applied; after that
  # editing it is a silent divergence (the version is in schema_migrations, so
  # the change never re-runs). Drift detection makes that an immediate error.
  def write_migration(root, body)
    dir = File.join(root, "app/modules/widgets/db/migrate")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "20260603000001_create_widgets_read.rb")
    File.write(path, body)
    path
  end

  V1 = <<~RUBY.freeze
    class CreateWidgetsRead < ActiveRecord::Migration[8.0]
      def change
        create_table(:widgets_read, id: false) { |t| t.string :id, null: false }
      end
    end
  RUBY

  it "raises when an already-applied migration's file changes on disk" do
    Dir.mktmpdir do |root|
      write_migration(root, V1)
      described_class.run(File.join(root, "app/modules"))

      # edit the applied migration (add a column) — a classic silent divergence
      write_migration(root, V1.sub("t.string :id, null: false", "t.string :id, null: false; t.string :name"))

      expect { described_class.run(File.join(root, "app/modules")) }
        .to raise_error(Shaolin::Error, /migration drift detected.*create_widgets_read/m)
    end
  end

  it "does not flag an applied migration whose file is unchanged (idempotent reruns)" do
    Dir.mktmpdir do |root|
      write_migration(root, V1)
      described_class.run(File.join(root, "app/modules"))
      expect { described_class.run(File.join(root, "app/modules")) }.not_to raise_error
    end
  end

  it "allows editing a migration that has not been applied yet" do
    Dir.mktmpdir do |root|
      # first run blesses nothing it hasn't applied; here we never apply before editing
      path = write_migration(root, V1)
      # tamper before any run records a checksum, then run once: no prior applied state
      File.write(path, V1.sub("t.string :id, null: false", "t.string :id, null: false; t.string :name"))
      expect { described_class.run(File.join(root, "app/modules")) }.not_to raise_error
      expect(ActiveRecord::Base.connection.column_exists?(:widgets_read, :name)).to be(true)
    end
  end
end

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
end

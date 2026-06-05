require "shaolin/cli"
require "tmpdir"

RSpec.describe Shaolin::CLI::Generators::FieldGenerator do
  def gen_module(name, root, es: false)
    g = Shaolin::CLI::Generators::ModuleGenerator.new([name], { "es" => es })
    g.destination_root = root
    g.invoke_all
  end

  def add_field(mod, spec, root)
    g = described_class.new([mod, spec])
    g.destination_root = root
    g.invoke_all
  end

  it "adds an add_column migration to a CRUD module (the table)" do
    Dir.mktmpdir do |root|
      gen_module("articles", root) # CRUD default
      add_field("articles", "views:integer", root)
      mig = Dir.glob(File.join(root, "app/modules/articles/db/migrate/*add_views*")).first
      expect(mig).not_to be_nil
      expect(File.read(mig)).to include("add_column :articles, :views, :integer").and(include("class AddViewsToArticles"))
    end
  end

  it "targets the read-model table for an event-sourced module" do
    Dir.mktmpdir do |root|
      gen_module("orders", root, es: true)
      add_field("orders", "amount:integer", root)
      mig = Dir.glob(File.join(root, "app/modules/orders/db/migrate/*add_amount*")).first
      expect(File.read(mig)).to include("add_column :orders_read, :amount, :integer")
    end
  end

  it "defaults the type to string" do
    Dir.mktmpdir do |root|
      gen_module("articles", root)
      add_field("articles", "slug", root)
      mig = Dir.glob(File.join(root, "app/modules/articles/db/migrate/*add_slug*")).first
      expect(File.read(mig)).to include("add_column :articles, :slug, :string")
    end
  end
end

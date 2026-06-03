require "shaolin/cli"
require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/http"
require "rack/test"
require "tmpdir"
require "json"

RSpec.describe Shaolin::CLI::Generators::ModuleGenerator do
  PG_CONFIG = {
    adapter: "postgresql", database: "shaolin_test",
    username: "postgres", host: "/tmp", port: 5433
  }.freeze

  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    ActiveRecord::Base.establish_connection(PG_CONFIG)
    conn = ActiveRecord::Base.connection
    conn.tables.each { |t| conn.drop_table(t, force: :cascade) }
  end

  def generate(name, root, crud: false)
    gen = described_class.new([name], { "crud" => crud })
    gen.destination_root = root
    gen.invoke_all
  end

  it "generates the canonical module files" do
    Dir.mktmpdir do |root|
      generate("widgets", root)
      base = File.join(root, "app/modules/widgets")
      %w[
        module.rb commands/create_widget.rb events/widget_created.rb widget.rb
        command_handlers/create_widget_handler.rb read_models/widget_record.rb
        projections/widgets_projection.rb dto/create_widget_dto.rb
        controllers/widgets_controller.rb CONTRACT.md
      ].each { |f| expect(File).to exist(File.join(base, f)), "missing #{f}" }
      expect(Dir.glob(File.join(base, "db/migrate/*_create_widgets_read.rb"))).not_to be_empty
      expect(File).to exist(File.join(root, "spec/widget_spec.rb"))
      expect(File).to exist(File.join(root, "spec/requests/widgets_spec.rb"))
    end
  end

  it "generates a module that boots and serves the full CQRS/ES flow" do
    Dir.mktmpdir do |root|
      generate("widgets", root)

      Shaolin::AR.register_provider!(config: PG_CONFIG)
      Shaolin::CQRS.register_provider!
      Shaolin::HTTP.register_provider!
      Shaolin::App.new(root: root).boot!
      Shaolin::AR::Migrator.run(File.join(root, "app/modules"))

      session = Rack::Test::Session.new(Shaolin::Kernel["http.app"])
      session.post("/widgets", JSON.generate(name: "Sprocket"), "CONTENT_TYPE" => "application/json")
      expect(session.last_response.status).to eq(201)

      location = session.last_response.headers["location"]
      session.get(location)
      expect(session.last_response.status).to eq(200)
      expect(JSON.parse(session.last_response.body)["name"]).to eq("Sprocket")
    end
  end

  it "gives modules generated in the same second distinct migration versions" do
    Dir.mktmpdir do |root|
      generate("posts", root)
      generate("tags", root, crud: true)
      versions = Dir.glob(File.join(root, "app/modules/*/db/migrate/*.rb"))
                    .map { |f| File.basename(f)[/\A\d+/] }
      expect(versions.uniq.size).to eq(versions.size)
    end
  end

  it "generates a --crud module (no event sourcing) that boots and serves" do
    Dir.mktmpdir do |root|
      generate("articles", root, crud: true)
      base = File.join(root, "app/modules/articles")
      expect(File).to exist(File.join(base, "article.rb"))
      expect(File).to exist(File.join(base, "controllers/articles_controller.rb"))
      expect(File).not_to exist(File.join(base, "events"))
      expect(File).not_to exist(File.join(base, "command_handlers"))

      Shaolin::AR.register_provider!(config: PG_CONFIG)
      Shaolin::CQRS.register_provider!
      Shaolin::HTTP.register_provider!
      Shaolin::App.new(root: root).boot!
      Shaolin::AR::Migrator.run(File.join(root, "app/modules"))

      session = Rack::Test::Session.new(Shaolin::Kernel["http.app"])
      session.post("/articles", JSON.generate(name: "Hello"), "CONTENT_TYPE" => "application/json")
      expect(session.last_response.status).to eq(201)

      location = session.last_response.headers["location"]
      session.get(location)
      expect(session.last_response.status).to eq(200)
      expect(JSON.parse(session.last_response.body)["name"]).to eq("Hello")
    end
  end
end

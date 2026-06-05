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
    adapter: "postgresql",
    database: ENV.fetch("DB_NAME", "shaolin_test"),
    username: ENV.fetch("DB_USER", "postgres"),
    password: ENV["PGPASSWORD"],
    host: ENV.fetch("DB_HOST", "/tmp"),
    port: Integer(ENV.fetch("DB_PORT", "5433"))
  }.freeze

  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    ActiveRecord::Base.establish_connection(PG_CONFIG)
    conn = ActiveRecord::Base.connection
    conn.tables.each { |t| conn.drop_table(t, force: :cascade) }
  end

  def generate(name, root, es: false, crud: false, reactor: false)
    gen = described_class.new([name], { "es" => es, "crud" => crud, "reactor" => reactor })
    gen.destination_root = root
    gen.invoke_all
  end

  it "defaults to a plain CRUD module (no event sourcing)" do
    Dir.mktmpdir do |root|
      generate("widgets", root) # no flags -> CRUD
      base = File.join(root, "app/modules/widgets")
      expect(File).to exist(File.join(base, "widget.rb"))
      expect(File).to exist(File.join(base, "controllers/widgets_controller.rb"))
      expect(File).not_to exist(File.join(base, "events"))
      expect(File).not_to exist(File.join(base, "command_handlers"))
    end
  end

  it "generates the canonical event-sourced module files with --es" do
    Dir.mktmpdir do |root|
      generate("widgets", root, es: true)
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

  it "boots + migrates a module whose name camelizes to an acronym (api_keys -> APIKeys)" do
    Dir.mktmpdir do |root|
      generate("api_keys", root, es: true)

      # the migration class must match AR's filename->constant rule, not the
      # dry-inflector namespace (which would be CreateAPIKeysRead -> NameError)
      migration = Dir.glob(File.join(root, "app/modules/api_keys/db/migrate/*.rb")).first
      expect(File.read(migration)).to include("class CreateApiKeysRead")

      Shaolin::AR.register_provider!(config: PG_CONFIG)
      Shaolin::CQRS.register_provider!
      Shaolin::HTTP.register_provider!
      Shaolin::App.new(root: root).boot!
      expect { Shaolin::AR::Migrator.run(File.join(root, "app/modules")) }.not_to raise_error
      expect(ActiveRecord::Base.connection.table_exists?("api_keys_read")).to be(true)
    end
  end

  it "generates a module that boots and serves the full CQRS/ES flow" do
    Dir.mktmpdir do |root|
      generate("widgets", root, es: true)

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

  it "scaffolds a reactor + spec with --es --reactor" do
    Dir.mktmpdir do |root|
      generate("orders", root, es: true, reactor: true)
      base = File.join(root, "app/modules/orders")
      reactor = File.join(base, "reactors/order_reactor.rb")
      expect(File).to exist(reactor)
      expect(File).to exist(File.join(root, "spec/reactors/order_reactor_spec.rb"))
      src = File.read(reactor)
      expect(src).to include("class OrderReactor < Shaolin::Jobs::Reactor")
      expect(src).to include("on(Orders::Events::OrderCreated)")
    end
  end

  it "refuses --reactor without --es (a CRUD module has no events)" do
    Dir.mktmpdir do |root|
      expect { generate("notes", root, reactor: true) }.to raise_error(Thor::Error, /reactor/)
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

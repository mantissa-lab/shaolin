require "shaolin/cli"
require "shaolin/cli/open_api"
require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/http"
require "tmpdir"

RSpec.describe Shaolin::CLI::OpenAPI do
  DB_CONFIG = {
    adapter: "postgresql", database: ENV.fetch("DB_NAME", "shaolin_test"),
    username: ENV.fetch("DB_USER", "postgres"), password: ENV["PGPASSWORD"],
    host: ENV.fetch("DB_HOST", "/tmp"), port: Integer(ENV.fetch("DB_PORT", "5433"))
  }.freeze

  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    ActiveRecord::Base.establish_connection(DB_CONFIG)
    ActiveRecord::Base.connection.tables.each { |t| ActiveRecord::Base.connection.drop_table(t, force: :cascade) }
  end

  it "builds an OpenAPI 3.1 doc: templatized paths, DTO request schema, error responses" do
    Dir.mktmpdir do |root|
      gen = Shaolin::CLI::Generators::ModuleGenerator.new(["products"], { "crud" => true })
      gen.destination_root = root
      gen.invoke_all

      Shaolin::AR.register_provider!(config: DB_CONFIG)
      Shaolin::CQRS.register_provider!
      Shaolin::HTTP.register_provider!
      Shaolin::App.new(root: root).boot!

      doc = described_class.generate(Shaolin::Kernel["kernel.containers"], File.join(root, "app/modules"))

      expect(doc["openapi"]).to eq("3.1.0")
      expect(doc["paths"].keys).to include("/products", "/products/{id}") # :id templatized
      expect(doc["paths"]["/products"]).to have_key("post")
      expect(doc["paths"]["/products"]).to have_key("get")

      post = doc["paths"]["/products"]["post"]
      ref = post.dig("requestBody", "content", "application/json", "schema", "$ref")
      expect(ref).to match(%r{#/components/schemas/\w+DTO})
      expect(post["responses"]).to have_key("422")

      schema_name = ref.split("/").last
      expect(doc["components"]["schemas"][schema_name]).to include("type" => "object")
      expect(doc["components"]["schemas"]).to have_key("Error")

      # path param surfaced
      id_param = doc["paths"]["/products/{id}"]["get"]["parameters"].first
      expect(id_param).to include("name" => "id", "in" => "path")
    end
  end
end

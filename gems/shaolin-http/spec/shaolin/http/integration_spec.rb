require "shaolin/http"
require "shaolin/cqrs"
require "rack/test"
require "tmpdir"
require "fileutils"
require "json"

# A command referenced by the generated controller (defined before boot so the
# controller file can resolve it at load time).
class RegisterUser
  attr_reader :name
  def initialize(name:) = (@name = name)
end

RSpec.describe "shaolin-http integration" do
  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
  end

  def build_and_boot
    Dir.mktmpdir do |root|
      controllers = File.join(root, "app/modules/users/controllers")
      FileUtils.mkdir_p(controllers)
      File.write(File.join(root, "app/modules/users/module.rb"), 'Shaolin.module("users") {}')
      File.write(File.join(controllers, "users_controller.rb"), <<~RUBY)
        module Users
          module Controllers
            class UsersController < Shaolin::HTTP::Controller
              routes do
                get "/users/:id", :show
                post "/users", :create
              end

              def show(req) = json({ id: req[:id] })

              def create(req)
                command_bus.call(RegisterUser.new(name: req[:name]))
                created({ name: req[:name] }, location: "/users/1")
              end
            end
          end
        end
      RUBY

      Shaolin::CQRS.register_provider!
      Shaolin::HTTP.register_provider!
      Shaolin::App.new(root: root).boot!
      yield Shaolin::Kernel["http.app"]
    end
  end

  it "serves health, path params, and dispatches a command end-to-end" do
    build_and_boot do |rack_app|
      recorded = []
      Shaolin::Kernel["cqrs.command_bus"].register(RegisterUser, ->(cmd) { recorded << cmd.name })

      session = Rack::Test::Session.new(rack_app)

      session.get("/healthz")
      expect(session.last_response.status).to eq(200)

      session.get("/users/42")
      expect(session.last_response.status).to eq(200)
      expect(JSON.parse(session.last_response.body)).to eq("id" => "42")

      session.post("/users", JSON.generate(name: "Jane"), "CONTENT_TYPE" => "application/json")
      expect(session.last_response.status).to eq(201)
      expect(session.last_response.headers["location"]).to eq("/users/1")
      expect(recorded).to eq(["Jane"])

      session.get("/missing")
      expect(session.last_response.status).to eq(404)
    end
  end
end

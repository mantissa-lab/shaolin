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
    Shaolin::Health.reset!
  end

  def build_and_boot(middleware: [], swagger: false)
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
                get "/boom", :boom
                get "/conflict", :conflict
              end

              def show(req) = json({ id: req[:id] })

              def create(req)
                command_bus.call(RegisterUser.new(name: req[:name]))
                created({ name: req[:name] }, location: "/users/1")
              end

              def boom(_req) = raise "kaboom secret stacktrace"
              def conflict(_req) = raise RubyEventStore::WrongExpectedEventVersion, "stale"
            end
          end
        end
      RUBY

      Shaolin::CQRS.register_provider!
      Shaolin::HTTP.register_provider!(middleware: middleware, swagger: swagger,
                                       modules_dir: File.join(root, "app/modules"))
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

  it "echoes an x-request-id on every response" do
    build_and_boot do |rack_app|
      session = Rack::Test::Session.new(rack_app)
      session.get("/healthz")
      expect(session.last_response.headers["x-request-id"]).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  it "propagates an inbound X-Request-Id" do
    build_and_boot do |rack_app|
      session = Rack::Test::Session.new(rack_app)
      session.get("/healthz", {}, "HTTP_X_REQUEST_ID" => "trace-123")
      expect(session.last_response.headers["x-request-id"]).to eq("trace-123")
    end
  end

  it "rejects an over-large body with 413 (Content-Length)" do
    build_and_boot do |rack_app|
      session = Rack::Test::Session.new(rack_app)
      big = "x" * (Shaolin::HTTP::RewindableInput::MAX_BODY_BYTES + 1)
      session.post("/users", JSON.generate(name: big), "CONTENT_TYPE" => "application/json")
      expect(session.last_response.status).to eq(413)
      expect(JSON.parse(session.last_response.body).dig("error", "code")).to eq("payload_too_large")
    end
  end

  it "turns an unhandled exception into a 500 JSON error without leaking the message (production)" do
    begin
      ENV["SHAOLIN_ENV"] = "production"
      build_and_boot do |rack_app|
        session = Rack::Test::Session.new(rack_app)
        session.get("/boom")
        expect(session.last_response.status).to eq(500)
        body = JSON.parse(session.last_response.body)
        expect(body.dig("error", "code")).to eq("internal_error")
        expect(body.dig("error", "message")).to eq("internal server error")
        expect(session.last_response.body).not_to include("kaboom")
      end
    ensure
      ENV.delete("SHAOLIN_ENV")
    end
  end

  it "maps an optimistic-concurrency conflict to 409" do
    build_and_boot do |rack_app|
      session = Rack::Test::Session.new(rack_app)
      session.get("/conflict")
      expect(session.last_response.status).to eq(409)
      expect(JSON.parse(session.last_response.body).dig("error", "code")).to eq("conflict")
    end
  end

  it "serves /readyz green when checks pass and 503 when a dependency is down" do
    build_and_boot do |rack_app|
      session = Rack::Test::Session.new(rack_app)

      Shaolin::Health.register("database") { true }
      session.get("/readyz")
      expect(session.last_response.status).to eq(200)
      expect(JSON.parse(session.last_response.body)["checks"]).to eq("database" => true)

      Shaolin::Health.register("database") { false }
      session.get("/readyz")
      expect(session.last_response.status).to eq(503)
    end
  end

  it "exposes Prometheus metrics at /metrics" do
    build_and_boot do |rack_app|
      session = Rack::Test::Session.new(rack_app)
      session.get("/metrics")
      expect(session.last_response.status).to eq(200)
      expect(session.last_response.body).to include("shaolin_up 1")
    end
  end

  it "passes a request-scoped value from middleware to the controller via Shaolin::Context" do
    # middleware resolves an identity and stashes it; the action reads it back
    identity = ->(app) { ->(env) { Shaolin::Context[:project_id] = env["HTTP_X_PROJECT"]; app.call(env) } }

    Dir.mktmpdir do |root|
      controllers = File.join(root, "app/modules/things/controllers")
      FileUtils.mkdir_p(controllers)
      File.write(File.join(root, "app/modules/things/module.rb"), 'Shaolin.module("things") {}')
      File.write(File.join(controllers, "things_controller.rb"), <<~RUBY)
        module Things
          module Controllers
            class ThingsController < Shaolin::HTTP::Controller
              routes { get "/whoami", :whoami }
              def whoami(_req) = json({ project_id: Shaolin::Context[:project_id] })
            end
          end
        end
      RUBY

      Shaolin::CQRS.register_provider!
      Shaolin::HTTP.register_provider!(middleware: [identity])
      Shaolin::App.new(root: root).boot!
      session = Rack::Test::Session.new(Shaolin::Kernel["http.app"])

      session.get("/whoami", {}, "HTTP_X_PROJECT" => "acme")
      expect(JSON.parse(session.last_response.body)).to eq("project_id" => "acme")

      # cleared between requests — no leak when the header is absent
      session.get("/whoami")
      expect(JSON.parse(session.last_response.body)).to eq("project_id" => nil)
    end
  end

  it "serves the OpenAPI doc at /openapi.json and Swagger UI at /swagger when swagger: true" do
    build_and_boot(swagger: true) do |rack_app|
      session = Rack::Test::Session.new(rack_app)

      session.get("/openapi.json")
      expect(session.last_response.status).to eq(200)
      doc = JSON.parse(session.last_response.body)
      expect(doc["openapi"]).to eq("3.1.0")
      expect(doc["paths"]).to have_key("/users/{id}")

      session.get("/swagger")
      expect(session.last_response.status).to eq(200)
      expect(session.last_response.body).to include("swagger-ui", "/openapi.json")
    end
  end

  it "does not expose /openapi.json or /swagger by default" do
    build_and_boot do |rack_app|
      session = Rack::Test::Session.new(rack_app)
      session.get("/openapi.json")
      expect(session.last_response.status).to eq(404)
    end
  end

  it "runs a real Rack middleware from the hook (Rack::Auth::Basic)" do
    require "rack/auth/basic"
    auth = ->(app) { Rack::Auth::Basic.new(app, "shaolin") { |u, p| u == "admin" && p == "secret" } }

    build_and_boot(middleware: [auth]) do |rack_app|
      session = Rack::Test::Session.new(rack_app)

      session.get("/users/1")
      expect(session.last_response.status).to eq(401) # short-circuits before the router

      session.basic_authorize("admin", "secret")
      session.get("/users/1")
      expect(session.last_response.status).to eq(200)
    end
  end
end

require "shaolin/http"
require "dry/monads"
require "rack"

class DemoController < Shaolin::HTTP::Controller
  include Dry::Monads[:result]

  routes do
    get "/things/:id", :show
    post "/things", :create
  end

  def show(req)
    return render_result(Failure([:not_found, "no thing #{req[:id]}"])) if req[:id] == "0"

    render_result(Success(id: req[:id]))
  end

  def create(_req)
    render_result(Success(id: "new"), location: "/things/new")
  end
end

RSpec.describe Shaolin::HTTP::Controller do
  subject(:controller) { DemoController.new }

  def request_for(path, method: "GET", input: "")
    Shaolin::HTTP::Request.new(Rack::MockRequest.env_for(path, method: method, input: input))
  end

  it "collects declared routes" do
    expect(DemoController.route_set).to include(
      { method: :get, path: "/things/:id", action: :show },
      { method: :post, path: "/things", action: :create }
    )
  end

  it "renders Success as 200 JSON" do
    status, headers, body = controller.show(request_for("/things/5").tap { |r| r.params[:id] = "5" })
    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/json")
    expect(JSON.parse(body.first)).to eq("id" => "5")
  end

  it "renders Failure([:not_found]) as 404" do
    req = request_for("/things/0")
    req.params[:id] = "0"
    status, _h, body = controller.show(req)
    expect(status).to eq(404)
    expect(JSON.parse(body.first).dig("error", "code")).to eq("not_found")
  end

  it "renders created with a location header as 201" do
    status, headers, = controller.create(request_for("/things", method: "POST"))
    expect(status).to eq(201)
    expect(headers["location"]).to eq("/things/new")
  end
end

require "shaolin/server"

RSpec.describe "server adapters serve a real Rack app" do
  let(:rack_app) { ->(_env) { [200, { "content-type" => "text/plain" }, ["pong"]] } }

  def serve_and_get(adapter, port)
    config = Shaolin::Server::Config.new(env: { "HOST" => "127.0.0.1", "PORT" => port.to_s })
    thread = Thread.new { adapter.start(rack_app, config) }
    response = get_when_ready(port)
    [response, thread]
  ensure
    adapter.stop(timeout: 2)
    thread&.join(5) || thread&.kill
  end

  it "serves over Puma" do
    response, = serve_and_get(Shaolin::Server::Adapters::Puma.new, free_port)
    expect(response&.code).to eq("200")
    expect(response.body).to eq("pong")
  end

  it "serves over Falcon (async-first default)" do
    response, = serve_and_get(Shaolin::Server::Adapters::Falcon.new, free_port)
    expect(response&.code).to eq("200")
    expect(response.body).to eq("pong")
  end
end

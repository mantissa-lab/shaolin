require "shaolin/server"
require "shaolin/core"

RSpec.describe "Shaolin::Server.run startup banner (#19)" do
  # A no-op adapter: start returns immediately so run doesn't block.
  let(:adapter) do
    Class.new do
      def start(_app, _config) = nil
      def stop(**) = nil
    end.new
  end

  it "emits a structured server.started line (url + adapter) before serving" do
    config = Shaolin::Server::Config.new(env: { "HOST" => "127.0.0.1", "PORT" => "9999" })

    expect(Shaolin::Log).to receive(:emit)
      .with("info", "server.started", hash_including(url: "http://127.0.0.1:9999", adapter: :falcon))

    Shaolin::Server.run(->(_e) { [200, {}, []] }, config: config, adapter: adapter)
  end
end

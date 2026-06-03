require "shaolin/server"

RSpec.describe Shaolin::Server::Config do
  it "defaults to falcon on 0.0.0.0:8080 with a 10s graceful timeout" do
    cfg = described_class.new(env: {})
    expect(cfg.adapter).to eq(:falcon)
    expect(cfg.host).to eq("0.0.0.0")
    expect(cfg.port).to eq(8080)
    expect(cfg.graceful_timeout).to eq(10)
  end

  it "reads PORT and SHAOLIN_SERVER from env" do
    cfg = described_class.new(env: { "PORT" => "3000", "SHAOLIN_SERVER" => "puma" })
    expect(cfg.port).to eq(3000)
    expect(cfg.adapter).to eq(:puma)
  end
end

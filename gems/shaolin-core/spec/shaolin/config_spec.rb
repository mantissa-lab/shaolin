require "shaolin/core"

RSpec.describe Shaolin::Config do
  it "defaults modules_path and reads env" do
    cfg = Shaolin::Config.new(env: { "SHAOLIN_ENV" => "production" })
    expect(cfg.modules_path).to eq("app/modules")
    expect(cfg.env).to eq("production")
  end

  it "reads a custom modules_path from env" do
    cfg = Shaolin::Config.new(env: { "SHAOLIN_MODULES_PATH" => "lib/modules" })
    expect(cfg.modules_path).to eq("lib/modules")
    expect(cfg.env).to eq("development")
  end

  it "isolates config per instance" do
    a = Shaolin::Config.new(env: { "SHAOLIN_ENV" => "production" })
    b = Shaolin::Config.new(env: {})
    expect(a.env).to eq("production")
    expect(b.env).to eq("development")
  end
end

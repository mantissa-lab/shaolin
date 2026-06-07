require "shaolin/http"
require "shaolin/core"
require "json"

RSpec.describe Shaolin::HTTP::RateLimit do
  let(:store) { Shaolin::Store::Memory.new }
  let(:app) { ->(_env) { [200, {}, ["ok"]] } }

  it "allows up to the limit per window, then 429s with Retry-After" do
    mw = described_class.new(app, store: store, limit: 2, window: 60)
    env = { "REMOTE_ADDR" => "1.2.3.4" }

    expect(mw.call(env)[0]).to eq(200)
    expect(mw.call(env)[0]).to eq(200)
    status, headers, body = mw.call(env) # 3rd in the window
    expect(status).to eq(429)
    expect(headers["retry-after"]).to eq("60")
    expect(JSON.parse(body.first).dig("error", "code")).to eq("rate_limited")
  end

  it "keys independently per client and exposes remaining" do
    mw = described_class.new(app, store: store, limit: 1, window: 60)
    a = mw.call("REMOTE_ADDR" => "10.0.0.1")
    b = mw.call("REMOTE_ADDR" => "10.0.0.2") # different client → own budget
    expect(a[0]).to eq(200)
    expect(b[0]).to eq(200)
    expect(a[1]["x-ratelimit-limit"]).to eq("1")
    expect(mw.call("REMOTE_ADDR" => "10.0.0.1")[0]).to eq(429) # first client exhausted
  end

  it "supports a custom key (e.g. an identity) instead of IP" do
    mw = described_class.new(app, store: store, limit: 1, window: 60,
                             key: ->(env) { env["tenant"] })
    expect(mw.call("tenant" => "acme")[0]).to eq(200)
    expect(mw.call("tenant" => "acme")[0]).to eq(429)
    expect(mw.call("tenant" => "globex")[0]).to eq(200) # separate tenant budget
  end
end

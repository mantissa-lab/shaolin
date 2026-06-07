require "shaolin/http"

RSpec.describe Shaolin::HTTP::Response do
  it "renders status/headers/body and merges a cookie into Set-Cookie (secure defaults)" do
    status, headers, body = described_class.new(200, { "content-type" => "application/json" }, ["{}"])
                            .cookie(:crm_auth, "tok", max_age: 60)
                            .header("x-foo", "bar")
                            .to_rack

    expect(status).to eq(200)
    expect(headers["x-foo"]).to eq("bar")
    expect(headers["set-cookie"]).to include("crm_auth=tok", "Path=/", "Max-Age=60", "HttpOnly", "SameSite=Lax", "Secure")
    expect(body).to eq(["{}"])
  end

  it "destructures as a Rack tuple (back-compat)" do
    status, headers, body = described_class.new(201, { "a" => "b" }, ["x"])
    expect([status, headers, body]).to eq([201, { "a" => "b" }, ["x"]])
  end

  it "delete_cookie expires it" do
    _, headers, = described_class.new(200).delete_cookie(:crm_auth).to_rack
    expect(headers["set-cookie"]).to include("crm_auth=", "Max-Age=0")
  end

  it "emits an array when multiple cookies are set" do
    _, headers, = described_class.new(200).cookie(:a, "1").cookie(:b, "2").to_rack
    expect(headers["set-cookie"]).to be_an(Array)
    expect(headers["set-cookie"].size).to eq(2)
  end
end

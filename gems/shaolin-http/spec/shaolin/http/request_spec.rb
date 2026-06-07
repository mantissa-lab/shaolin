require "shaolin/http"
require "rack"
require "rack/test"
require "stringio"

RSpec.describe Shaolin::HTTP::Request do
  def request_for(env) = described_class.new(env)

  it "parses a JSON body into symbol-keyed params (default)" do
    env = Rack::MockRequest.env_for("/x", method: "POST", input: '{"name":"Widget"}',
                                    "CONTENT_TYPE" => "application/json")
    expect(request_for(env)[:name]).to eq("Widget")
  end

  it "parses multipart/form-data: text fields in params, uploads in #files (with bytes)" do
    file = Rack::Test::UploadedFile.new(StringIO.new("PNGBYTES"), "image/png", original_filename: "logo.png")
    data = Rack::Test::Utils.build_multipart("caption" => "hi", "image" => file)
    env = Rack::MockRequest.env_for("/upload", method: "POST", input: data,
                                    "CONTENT_TYPE" => "multipart/form-data; boundary=#{Rack::Test::MULTIPART_BOUNDARY}",
                                    "CONTENT_LENGTH" => data.bytesize.to_s)

    req = request_for(env)
    expect(req[:caption]).to eq("hi")
    expect(req.files[:image]).to include(filename: "logo.png", type: "image/png", bytes: "PNGBYTES")
  end

  it "parses application/x-www-form-urlencoded into params" do
    env = Rack::MockRequest.env_for("/x", method: "POST", params: { a: "1", b: "2" })
    req = request_for(env)
    expect(req[:a]).to eq("1")
    expect(req[:b]).to eq("2")
    expect(req.files).to eq({})
  end

  it "returns no files for a non-multipart request" do
    env = Rack::MockRequest.env_for("/x", method: "POST", input: "{}", "CONTENT_TYPE" => "application/json")
    expect(request_for(env).files).to eq({})
  end
end

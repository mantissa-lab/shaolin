require "shaolin/http"
require "shaolin/http/web_socket"
require "async/websocket/client"
require "async/http/endpoint"

RSpec.describe Shaolin::HTTP::WebSocket::Socket do
  Frame = Struct.new(:buffer)

  # A stand-in async-websocket connection: hands out canned inbound frames, then
  # nil (peer closed); records sends + close.
  class FakeConn
    attr_reader :sent, :closed

    def initialize(frames)
      @frames = frames.dup
      @sent = []
      @closed = false
    end

    def read = @frames.shift
    def send_text(s) = @sent << [:text, s]
    def send_binary(b) = @sent << [:binary, b]
    def flush = nil
    def close = (@closed = true)
  end

  it "drives open → message* → close, and echoes via send" do
    conn = FakeConn.new([Frame.new("hi"), Frame.new("there")])
    log = []
    socket = described_class.new(conn)
    socket.on_open { log << :open }
    socket.on_message { |data, s| log << [:msg, data]; s.send("echo:#{data}") }
    socket.on_close { log << :close }

    socket.run

    expect(log).to eq([:open, [:msg, "hi"], [:msg, "there"], :close])
    expect(conn.sent).to eq([[:text, "echo:hi"], [:text, "echo:there"]])
    expect(conn.closed).to be(true)
  end

  it "sends binary frames when binary: true" do
    conn = FakeConn.new([])
    described_class.new(conn).send("\x00\x01", binary: true)
    expect(conn.sent).to eq([[:binary, "\x00\x01"]])
  end

  it "connect: a general client wraps ANY ws server with the same Socket API (domain-agnostic)" do
    conn = FakeConn.new([Frame.new("pong")])
    allow(Async::HTTP::Endpoint).to receive(:parse).with("wss://asterisk/ari").and_return(:endpoint)
    allow(Async::WebSocket::Client).to receive(:connect).with(:endpoint, headers: [%w[authorization Bearer]]).and_yield(conn)

    got = []
    Shaolin::HTTP::WebSocket.connect("wss://asterisk/ari", headers: { "authorization" => "Bearer" }) do |s|
      s.on_message { |data, sock| got << data; sock.send("ack") }
    end

    expect(got).to eq(["pong"])              # received from the remote server
    expect(conn.sent).to eq([[:text, "ack"]]) # sent back — not realtime/LLM-specific
  end

  it "routes a read error to on_error and still fires on_close" do
    conn = Object.new
    def conn.read = raise("boom")
    def conn.close = nil
    err = nil
    closed = false
    socket = described_class.new(conn)
    socket.on_error { |e, _| err = e }
    socket.on_close { closed = true }

    socket.run

    expect(err.message).to eq("boom")
    expect(closed).to be(true)
  end
end

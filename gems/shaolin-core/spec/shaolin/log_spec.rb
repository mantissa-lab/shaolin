require "shaolin/core"

RSpec.describe Shaolin::Log do
  let(:spy) { [] }

  before do
    Shaolin::Log.reset!
    Shaolin::Log.sinks = [->(record) { spy << record }]
    Shaolin::Log.level = :debug
    Shaolin::Tenant.current = nil
  end

  after { Shaolin::Log.reset! }

  it "emits a structured record (ts, level, msg, fields) to every sink" do
    described_class.info("user_registered", id: "u1")
    rec = spy.first
    expect(rec[:level]).to eq("info")
    expect(rec[:msg]).to eq("user_registered")
    expect(rec[:id]).to eq("u1")
    expect(rec[:ts]).to match(/\dT\d/)
  end

  it "filters out records below the configured level" do
    described_class.level = :warn
    described_class.info("ignored")
    described_class.error("kept")
    expect(spy.map { |r| r[:msg] }).to eq(["kept"])
  end

  it "merges fiber/thread-local context and restores it after the block" do
    described_class.with(request_id: "req-1") do
      described_class.info("inside")
    end
    described_class.info("outside")
    expect(spy[0][:request_id]).to eq("req-1")
    expect(spy[1]).not_to have_key(:request_id)
  end

  it "auto-attaches the current tenant" do
    Shaolin::Tenant.with("acme") { described_class.info("scoped") }
    expect(spy.first[:tenant]).to eq("acme")
  end

  it "is silenced by SHAOLIN_LOG=off" do
    ENV["SHAOLIN_LOG"] = "off"
    described_class.info("nope")
    ENV.delete("SHAOLIN_LOG")
    expect(spy).to be_empty
  end

  describe Shaolin::Log::Sinks::Batch do
    it "flushes a batch when the buffer hits the size threshold" do
      flushed = []
      batch = described_class.new(flush_size: 2) { |records| flushed << records }
      batch.call({ msg: "a" })
      expect(flushed).to be_empty
      batch.call({ msg: "b" })
      expect(flushed.first.map { |r| r[:msg] }).to eq(%w[a b])
    end

    it "flushes the remainder on explicit #flush" do
      flushed = []
      batch = described_class.new(flush_size: 100) { |records| flushed << records }
      batch.call({ msg: "x" })
      batch.flush
      expect(flushed.first.map { |r| r[:msg] }).to eq(["x"])
    end
  end
end

require "shaolin/server"
require "async"

RSpec.describe Shaolin::Server::Timeout do
  it "returns 503 when the handler exceeds the deadline (cooperative, frees the fiber)" do
    result = nil
    Async do
      slow = ->(_e) { sleep 5; [200, {}, ["late"]] } # cooperative sleep under the reactor
      result = described_class.new(slow, 0.05).call({})
    end
    expect(result[0]).to eq(503)
    expect(result[2].first).to include("timeout")
  end

  it "passes a fast handler through unchanged" do
    result = nil
    Async do
      result = described_class.new(->(_e) { [200, {}, ["ok"]] }, 1.0).call({})
    end
    expect(result).to eq([200, {}, ["ok"]])
  end

  it "is inert outside an async reactor (e.g. Puma) — no current task, no timeout" do
    expect(described_class.new(->(_e) { [200, {}, ["ok"]] }, 0.001).call({})).to eq([200, {}, ["ok"]])
  end
end

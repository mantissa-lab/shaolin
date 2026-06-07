require "shaolin/http"
require "json"

RSpec.describe Shaolin::HTTP::Concurrency do
  before { Shaolin::Kernel.reset! }

  it "load-sheds with 503 past the cap and tracks the in-flight gauge" do
    entered = Queue.new
    release = Queue.new
    app = ->(_env) { entered << :in; release.pop; [200, {}, ["ok"]] }
    mw = described_class.new(app, max: 1)

    busy = Thread.new { mw.call({}) } # takes the only permit, blocks in the app
    entered.pop
    expect(mw.in_flight).to eq(1)

    status, _h, body = mw.call({}) # second concurrent request → shed
    expect(status).to eq(503)
    expect(JSON.parse(body.first).dig("error", "code")).to eq("overloaded")

    release << :go
    busy.join
    expect(mw.in_flight).to eq(0)
  end

  it "registers itself so /metrics can report in-flight + the cap" do
    described_class.new(->(_e) { [200, {}, []] }, max: 7)
    out = Shaolin::HTTP::Metrics.render
    expect(out).to include("shaolin_http_concurrency_max 7")
    expect(out).to include("shaolin_http_in_flight 0")
  end

  it "Metrics reports outbox depth + worker lag when the outbox is wired" do
    Shaolin::Kernel.register("jobs.outbox", double(stats: { "pending" => 3 }, oldest_pending_age: 4.5))
    out = Shaolin::HTTP::Metrics.render
    expect(out).to include('shaolin_outbox_jobs{status="pending"} 3')
    expect(out).to include("shaolin_outbox_oldest_pending_seconds 4.5")
  end
end

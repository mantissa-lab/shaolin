require "shaolin/jobs"
require "support/pg"
require "securerandom"

# Operational helpers behind `shaolin jobs stats|dead|retry`.
RSpec.describe "Shaolin::Jobs::Outbox operations" do
  before do
    PgTest.reset_schema!
    Shaolin::Jobs::Schema.create!
  end

  let(:outbox) { Shaolin::Jobs::Outbox.new }

  def make(status:, id: SecureRandom.uuid)
    Shaolin::Jobs::OutboxJob.create!(
      reactor: "R", event_id: id, event_type: "E", payload: "",
      status: status, run_at: Time.now, last_error: (status == "dead" ? "boom" : nil)
    )
  end

  it "reports counts by status" do
    make(status: "pending")
    make(status: "pending")
    make(status: "dead")
    expect(outbox.stats).to eq("pending" => 2, "dead" => 1)
  end

  it "reports worker lag as the age of the oldest due pending job" do
    expect(outbox.oldest_pending_age).to eq(0.0) # nothing pending
    Shaolin::Jobs::OutboxJob.create!(reactor: "R", event_id: SecureRandom.uuid, event_type: "E",
                                     payload: "", status: "pending", run_at: Time.now - 30)
    expect(outbox.oldest_pending_age).to be >= 30.0
  end

  it "lists dead-lettered jobs" do
    dead = make(status: "dead")
    expect(outbox.dead.map(&:id)).to eq([dead.id])
  end

  it "re-queues a dead job (pending, attempts reset)" do
    dead = make(status: "dead")
    expect(outbox.retry!(dead.id)).to eq(1)
    dead.reload
    expect(dead.status).to eq("pending")
    expect(dead.attempts).to eq(0)
    expect(dead.last_error).to be_nil
  end

  it "won't re-queue a non-dead job" do
    pending = make(status: "pending")
    expect(outbox.retry!(pending.id)).to eq(0)
  end
end

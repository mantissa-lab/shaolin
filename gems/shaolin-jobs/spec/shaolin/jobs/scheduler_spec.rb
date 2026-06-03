require "shaolin/jobs"
require "support/pg"

RSpec.describe Shaolin::Jobs::Scheduler do
  before do
    Shaolin::Jobs::Schedules.reset!
    PgTest.reset_schema!
    ActiveRecord::Base.establish_connection(PgTest::CONFIG)
    Shaolin::Jobs::Schema.create!
    $sched_fired = Queue.new
  end

  it "fires a due schedule and skips one that isn't due yet" do
    Shaolin.schedule("tick_task", every: "1h") { $sched_fired << :ran }

    fired = described_class.new.tick(now: Time.now)
    expect(fired).to eq(["tick_task"])
    expect($sched_fired.size).to eq(1)

    described_class.new.tick(now: Time.now) # interval not elapsed → not due
    expect($sched_fired.size).to eq(1)
  end

  it "#5 two scheduler replicas fire a due task exactly once (advisory-lock leader)" do
    Shaolin.schedule("once", every: "1h") do
      $sched_fired << :ran
      sleep 0.1 # hold the leader lock so the other replica's tick overlaps
    end

    latch = Queue.new
    threads = Array.new(2) do
      Thread.new do
        latch.pop
        ActiveRecord::Base.connection_pool.with_connection { described_class.new.tick }
      end
    end
    2.times { latch << :go }
    threads.each(&:join)

    expect($sched_fired.size).to eq(1) # only the leader fired it
    expect(Shaolin::Jobs::ScheduleRun.where(name: "once").count).to eq(1)
  end
end

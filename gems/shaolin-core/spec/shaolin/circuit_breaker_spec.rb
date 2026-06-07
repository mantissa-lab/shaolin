require "shaolin/core"

RSpec.describe Shaolin::CircuitBreaker do
  it "opens after the failure threshold and fast-fails without calling the block" do
    breaker = described_class.new(threshold: 2, reset_timeout: 30)
    2.times { expect { breaker.call { raise "boom" } }.to raise_error("boom") }
    expect(breaker.state).to eq(:open)

    called = false
    expect { breaker.call { called = true } }.to raise_error(Shaolin::CircuitBreaker::OpenError)
    expect(called).to be(false) # the doomed call was never attempted
  end

  it "half-opens after the cooldown and closes on a successful trial" do
    now = 0.0
    breaker = described_class.new(threshold: 1, reset_timeout: 10, clock: -> { now })
    expect { breaker.call { raise "boom" } }.to raise_error("boom")
    expect(breaker.state).to eq(:open)

    now = 11.0 # cooldown elapsed
    expect(breaker.state).to eq(:half_open)
    expect(breaker.call { :ok }).to eq(:ok) # trial succeeds
    expect(breaker.state).to eq(:closed)
  end

  it "resets the failure count on success while closed" do
    breaker = described_class.new(threshold: 3)
    expect { breaker.call { raise "x" } }.to raise_error("x")
    breaker.call { :ok } # success resets
    expect { breaker.call { raise "x" } }.to raise_error("x")
    expect(breaker.state).to eq(:closed) # 1 failure, not 2 → still closed
  end
end

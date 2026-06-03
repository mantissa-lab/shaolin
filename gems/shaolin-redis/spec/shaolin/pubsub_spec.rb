require "spec_helper"

RSpec.describe Shaolin::Redis::PubSub do
  let(:pool) { Shaolin::Redis::Connection.pool(url: REDIS_TEST_URL) }
  subject(:pubsub) { described_class.new(pool: pool, url: REDIS_TEST_URL) }

  it "returns 0 receivers when nobody is listening" do
    expect(pubsub.publish("empty", "hi")).to eq(0)
  end

  it "delivers a published message to a live subscriber" do
    got = Queue.new
    sub = Thread.new do
      pubsub.subscribe("room", timeout: 2) { |_ch, msg| got << msg }
    rescue StandardError
      # subscribe_with_timeout raises after silence — fine, the test is done
    end

    # publish only succeeds (==1) once the subscriber is registered
    sleep 0.05 until pubsub.publish("room", "ping") == 1
    expect(got.pop).to eq("ping")
  ensure
    sub&.kill
  end

  it "JSON-encodes non-string payloads on publish" do
    got = Queue.new
    sub = Thread.new do
      pubsub.subscribe("json", timeout: 2) { |_ch, msg| got << msg }
    rescue StandardError
    end

    sleep 0.05 until pubsub.publish("json", { a: 1 }) == 1
    expect(got.pop).to eq('{"a":1}')
  ensure
    sub&.kill
  end
end

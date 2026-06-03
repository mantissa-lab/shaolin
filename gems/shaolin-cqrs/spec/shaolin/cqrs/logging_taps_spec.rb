require "shaolin/cqrs"

# SHAOLIN_LOG_EVERYTHING turns the buses into a firehose onto Shaolin::Log.
RSpec.describe "CQRS logging taps (SHAOLIN_LOG_EVERYTHING)" do
  let(:logged) { [] }

  around do |example|
    prev = ENV["SHAOLIN_LOG_EVERYTHING"]
    ENV["SHAOLIN_LOG_EVERYTHING"] = "1"
    Shaolin::Log.reset!
    Shaolin::Log.sinks = [->(record) { logged << record }]
    Shaolin::Log.level = :debug
    example.run
  ensure
    ENV["SHAOLIN_LOG_EVERYTHING"] = prev
    Shaolin::Log.reset!
  end

  it "logs every command dispatched through the bus" do
    klass = Class.new
    bus = Shaolin::CQRS::CommandBus.new
    bus.register(klass, ->(_cmd) { :ok })
    bus.call(klass.new)
    expect(logged.map { |r| r[:msg] }).to include("command")
  end

  it "logs every query dispatched through the bus" do
    klass = Class.new
    bus = Shaolin::CQRS::QueryBus.new
    bus.register(klass, ->(_q) { :ok })
    bus.call(klass.new)
    expect(logged.map { |r| r[:msg] }).to include("query")
  end

  it "does not log when the firehose is off" do
    ENV["SHAOLIN_LOG_EVERYTHING"] = "0"
    klass = Class.new
    bus = Shaolin::CQRS::CommandBus.new
    bus.register(klass, ->(_cmd) { :ok })
    bus.call(klass.new)
    expect(logged).to be_empty
  end
end

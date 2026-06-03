require "shaolin/server"

RSpec.describe Shaolin::Server::Adapters do
  it "builds the falcon and puma adapters" do
    expect(described_class.build(:falcon)).to be_a(Shaolin::Server::Adapters::Falcon)
    expect(described_class.build(:puma)).to be_a(Shaolin::Server::Adapters::Puma)
  end

  it "raises on an unknown adapter" do
    expect { described_class.build(:webrick) }.to raise_error(Shaolin::Error, /unknown server adapter/)
  end
end

RSpec.describe Shaolin::Server do
  it "run passes the rack app and config to the adapter" do
    captured = {}
    fake = Object.new
    fake.define_singleton_method(:start) { |app, config| captured[:app] = app; captured[:config] = config }
    fake.define_singleton_method(:stop) { |**| }

    config = Shaolin::Server::Config.new(env: {})
    described_class.run(:the_rack_app, config: config, adapter: fake)

    expect(captured[:app]).to eq(:the_rack_app)
    expect(captured[:config]).to be(config)
  end
end

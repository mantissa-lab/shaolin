require "shaolin/cqrs"
require "tmpdir"
require "fileutils"

RSpec.describe "shaolin-cqrs :cqrs provider" do
  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
  end

  def boot_app_with_user_module
    Dir.mktmpdir do |root|
      dir = File.join(root, "app/modules/users")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "module.rb"), 'Shaolin.module("users") {}')
      yield Shaolin::App.new(root: root).boot!
    end
  end

  it "exposes cqrs.* services to a module via the kernel fallback" do
    Shaolin::CQRS.register_provider!

    boot_app_with_user_module do |app|
      expect(app["users"]["cqrs.command_bus"]).to be_a(Shaolin::CQRS::CommandBus)
      expect(app["users"]["cqrs.query_bus"]).to be_a(Shaolin::CQRS::QueryBus)
      expect(app["users"]["cqrs.event_store"]).to be_a(RubyEventStore::Client)
      expect(app["users"]["cqrs.aggregate_repository"]).to be_a(Shaolin::CQRS::AggregateRepository)
    end
  end

  it "uses an injected event-store backend when one is registered" do
    Shaolin::Kernel.register("cqrs.event_store_backend", RubyEventStore::InMemoryRepository.new)
    Shaolin::CQRS.register_provider!
    Shaolin::Provider.start_all

    expect(Shaolin::Kernel["cqrs.event_store"]).to be_a(RubyEventStore::Client)
  end
end

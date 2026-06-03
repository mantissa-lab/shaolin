require "shaolin/cli"
require "shaolin/cli/describe"
require "tmpdir"
require "fileutils"

RSpec.describe Shaolin::CLI::Describe do
  def write_module(root, name, body)
    dir = File.join(root, "app/modules", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "module.rb"), body)
    File.join(root, "app/modules")
  end

  it "builds an app map from module manifests" do
    Dir.mktmpdir do |root|
      modules = write_module(root, "users", <<~RUBY)
        Shaolin.module "users" do
          imports "notifications.mailer"
          exports "user_service"
          commands_handled "Users::Commands::RegisterUser"
          events_published "users.user_registered"
        end
      RUBY

      result = described_class.map(modules)
      users = result[:modules].find { |m| m[:name] == "users" }

      expect(users[:imports]).to eq(["notifications.mailer"])
      expect(users[:exports]).to eq(["user_service"])
      expect(users[:commands_handled]).to eq(["Users::Commands::RegisterUser"])
      expect(users[:events_published]).to eq(["users.user_registered"])
      expect(result[:ruby]).to eq(RUBY_VERSION)
    end
  end

  it "produces a command/event surface for schemas" do
    Dir.mktmpdir do |root|
      modules = write_module(root, "orders", <<~RUBY)
        Shaolin.module "orders" do
          commands_handled "Orders::Commands::CreateOrder"
          events_published "orders.order_created"
        end
      RUBY

      schema = described_class.schemas(modules).find { |m| m[:name] == "orders" }
      expect(schema[:commands]).to eq(["Orders::Commands::CreateOrder"])
      expect(schema[:events]).to eq(["orders.order_created"])
    end
  end
end

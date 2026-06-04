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

  it "includes each module's reactors (with subscribed events) and scheduled tasks" do
    Dir.mktmpdir do |root|
      modules = write_module(root, "signups", <<~RUBY)
        Shaolin.module "signups" do
          events_published "signups.signup_completed"
        end
      RUBY
      FileUtils.mkdir_p(File.join(root, "app/modules/signups/reactors"))
      File.write(File.join(root, "app/modules/signups/reactors/notify_reactor.rb"), <<~RUBY)
        module Signups
          module Reactors
            class NotifyReactor < Shaolin::Jobs::Reactor
              on(Signups::Events::SignupCompleted) { |e| nil }
            end
          end
        end
      RUBY
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/schedule.rb"), <<~RUBY)
        Shaolin.schedule("nightly_digest", every: "1d") { nil }
      RUBY

      result = described_class.map(modules)
      signups = result[:modules].find { |m| m[:name] == "signups" }

      expect(signups[:reactors]).to eq([
        { class: "NotifyReactor", on: ["Signups::Events::SignupCompleted"], topics: [], file: "notify_reactor.rb" }
      ])
      expect(result[:scheduled]).to include(name: "nightly_digest", every: "1d")
    end
  end

  it "shows a reactor's cross-module topic subscriptions and the module's subscribed topics" do
    Dir.mktmpdir do |root|
      modules = write_module(root, "dispatches", <<~RUBY)
        Shaolin.module "dispatches" do
          imports events: ["conversions.conversion_recorded"]
        end
      RUBY
      FileUtils.mkdir_p(File.join(root, "app/modules/dispatches/reactors"))
      File.write(File.join(root, "app/modules/dispatches/reactors/conversion_dispatcher.rb"), <<~RUBY)
        module Dispatches
          module Reactors
            class ConversionDispatcher < Shaolin::Jobs::Reactor
              on("conversions.conversion_recorded") { |e| nil }
            end
          end
        end
      RUBY

      mod = described_class.map(modules)[:modules].find { |m| m[:name] == "dispatches" }
      expect(mod[:events_subscribed]).to eq(["conversions.conversion_recorded"])
      expect(mod[:reactors]).to eq([
        { class: "ConversionDispatcher", on: [], topics: ["conversions.conversion_recorded"],
          file: "conversion_dispatcher.rb" }
      ])
    end
  end

  it "discovers harnesses under app/harnesses and maps their gates/tools/model/edges" do
    Dir.mktmpdir do |root|
      modules = File.join(root, "app/modules")
      FileUtils.mkdir_p(modules) # map globs module.rb here (none needed)
      FileUtils.mkdir_p(File.join(root, "app/harnesses"))
      File.write(File.join(root, "app/harnesses/billing_triage.rb"), <<~RUBY)
        require "shaolin/harness"
        class ChargeCard
          def initialize(**) = nil
        end
        class BillingTriage < Shaolin::Harness
          harness_name "billing_triage"
          llm model: "gpt-4.1"
          gate :classify, entry: true, to: %i[charge done] do
            tools charge: ChargeCard
            on_result { |_o, _r| }
          end
          gate :charge, to: %i[done] do
            on_result { |_o, _r| }
          end
          gate :done, terminal: true do
            on_result { |_o, _r| }
          end
        end
      RUBY

      result = described_class.map(modules)
      harness = result[:harnesses].find { |h| h[:name] == "billing_triage" }
      expect(harness[:model]).to eq("gpt-4.1")
      classify = harness[:gates].find { |g| g[:name] == "classify" }
      expect(classify).to include(entry: true, tools: ["charge"], to: %w[charge done])
      expect(harness[:gates].find { |g| g[:name] == "done" }[:terminal]).to be(true)
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

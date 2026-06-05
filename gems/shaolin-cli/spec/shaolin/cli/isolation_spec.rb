require "shaolin/cli"
require "shaolin/cli/isolation"
require "tmpdir"
require "fileutils"

RSpec.describe Shaolin::CLI::Isolation do
  def write(root, rel, content)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  it "flags cross-module references and require_relative escaping the module" do
    Dir.mktmpdir do |root|
      modules = File.join(root, "app/modules")
      # offending module: reaches into Billing + requires out of its folder
      write(modules, "users/notifier.rb", <<~RUBY)
        require_relative "../billing/invoice"
        module Users
          class Notifier
            def call = Billing::Invoice.new
          end
        end
      RUBY
      # clean modules
      write(modules, "billing/invoice.rb", "module Billing; class Invoice; end; end")
      write(modules, "orders/order.rb", "module Orders; class Order; def ok = Orders::Order; end; end")

      violations = described_class.new(modules).violations
      rules = violations.map(&:rule)
      expect(rules).to include("cross-module-reference", "require-escapes-module")

      offending_files = violations.map(&:file)
      expect(offending_files).to all(start_with("users/"))
    end
  end

  it "reports no violations for an isolated app" do
    Dir.mktmpdir do |root|
      modules = File.join(root, "app/modules")
      write(modules, "users/user.rb", "module Users; class User; def me = Users::User; end; end")
      write(modules, "billing/invoice.rb", "module Billing; class Invoice; end; end")

      expect(described_class.new(modules).violations).to be_empty
    end
  end

  it "does not flag a reactor that subscribes to another module's event by TOPIC STRING" do
    Dir.mktmpdir do |root|
      modules = File.join(root, "app/modules")
      write(modules, "conversions/events/conversion_recorded.rb",
            "module Conversions; module Events; class ConversionRecorded; end; end; end")
      # legit: string topic, no reference to Conversions:: constant
      write(modules, "dispatches/reactors/conversion_dispatcher.rb", <<~RUBY)
        module Dispatches
          module Reactors
            class ConversionDispatcher < Shaolin::Jobs::Reactor
              on("conversions.conversion_recorded") { |e| nil }
            end
          end
        end
      RUBY

      expect(described_class.new(modules).violations).to be_empty
    end
  end

  it "flags import(\"x\") when x is not declared in the module's manifest" do
    Dir.mktmpdir do |root|
      modules = File.join(root, "app/modules")
      write(modules, "billing/module.rb", 'Shaolin.module("billing") { imports "accounts.balance_reader" }')
      write(modules, "billing/charger.rb", <<~RUBY)
        module Billing
          class Charger
            def ok = import("accounts.balance_reader")   # declared -> clean
            def bad = import("accounts.secret")           # undeclared -> flagged
          end
        end
      RUBY

      violations = described_class.new(modules).violations
      undeclared = violations.select { |v| v.rule == "undeclared-import" }
      expect(undeclared.size).to eq(1)
      expect(undeclared.first.message).to include("accounts.secret")
    end
  end

  it "still flags a reactor that references another module's event CLASS" do
    Dir.mktmpdir do |root|
      modules = File.join(root, "app/modules")
      write(modules, "conversions/events/conversion_recorded.rb",
            "module Conversions; module Events; class ConversionRecorded; end; end; end")
      write(modules, "dispatches/reactors/bad_dispatcher.rb", <<~RUBY)
        module Dispatches
          module Reactors
            class BadDispatcher < Shaolin::Jobs::Reactor
              on(Conversions::Events::ConversionRecorded) { |e| nil }
            end
          end
        end
      RUBY

      rules = described_class.new(modules).violations.map(&:rule)
      expect(rules).to include("cross-module-reference")
    end
  end
end

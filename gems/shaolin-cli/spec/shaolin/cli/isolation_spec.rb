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
end

require "shaolin/core"
require "support/tmp_app"

RSpec.describe "module isolation" do
  include TmpApp

  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
  end

  it "lets a module resolve an imported export of another module" do
    with_app(
      "mailer" => {
        "module.rb" => 'Shaolin.module("mailer") { exports "mailer" }',
        "mailer.rb" => "module Mailer; class Mailer; def deliver = :sent; end; end"
      },
      "users" => {
        "module.rb" => 'Shaolin.module("users") { imports "mailer.mailer" }',
        "notifier.rb" => "module Users; class Notifier; def call = :noop; end; end"
      }
    ) do |root|
      app = Shaolin::App.new(root: root).boot!
      expect(app["users"]["mailer.mailer"].deliver).to eq(:sent)
    end
  end

  it "raises IsolationError when resolving a non-imported key" do
    with_app(
      "users" => { "module.rb" => 'Shaolin.module("users") {}' }
    ) do |root|
      app = Shaolin::App.new(root: root).boot!
      expect { app["users"]["mailer.mailer"] }
        .to raise_error(Shaolin::IsolationError, /mailer\.mailer/)
    end
  end

  it "raises IsolationError when importing a key the owner does not export" do
    with_app(
      "mailer" => {
        "module.rb" => 'Shaolin.module("mailer") {}',
        "mailer.rb" => "module Mailer; class Mailer; def deliver = :sent; end; end"
      },
      "users" => { "module.rb" => 'Shaolin.module("users") { imports "mailer.mailer" }' }
    ) do |root|
      expect { Shaolin::App.new(root: root).boot! }
        .to raise_error(Shaolin::IsolationError, /mailer\.mailer/)
    end
  end

  it "raises ManifestError when exporting a non-existent component" do
    with_app(
      "users" => { "module.rb" => 'Shaolin.module("users") { exports "ghost" }' }
    ) do |root|
      expect { Shaolin::App.new(root: root).boot! }
        .to raise_error(Shaolin::ManifestError, /ghost/)
    end
  end
end

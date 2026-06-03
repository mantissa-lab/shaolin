require "shaolin/core"
require "support/tmp_app"

RSpec.describe Shaolin::App do
  include TmpApp

  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
  end

  it "discovers modules under modules_path and resolves their components" do
    with_app(
      "users" => {
        "module.rb"       => 'Shaolin.module("users") { exports "user_service" }',
        "user_service.rb" => "module Users; class UserService; def call = :ok; end; end"
      }
    ) do |root|
      app = Shaolin::App.new(root: root).boot!
      expect(app.modules).to eq(["users"])
      expect(app["users"]["user_service"].call).to eq(:ok)
    end
  end

  it "runs provider start hooks during boot" do
    started = []
    Shaolin.register_provider(:probe) { start { started << :probe } }

    with_app("users" => { "module.rb" => 'Shaolin.module("users") {}' }) do |root|
      Shaolin::App.new(root: root).boot!
      expect(started).to eq([:probe])
    end
  end
end

require "shaolin/core"
require "support/tmp_app"

RSpec.describe "container exposure for transports" do
  include TmpApp

  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
  end

  it "exposes local component keys and the container map" do
    with_app(
      "users" => {
        "module.rb"       => 'Shaolin.module("users") { exports "user_service" }',
        "user_service.rb" => "module Users; class UserService; end; end"
      }
    ) do |root|
      app = Shaolin::App.new(root: root).boot!

      expect(app["users"].keys).to include("user_service")

      containers = Shaolin::Kernel["kernel.containers"]
      expect(containers.keys).to eq(["users"])
      expect(containers["users"]).to be(app["users"])
    end
  end
end

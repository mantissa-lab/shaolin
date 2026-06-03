require "shaolin/core"
require "support/tmp_app"

RSpec.describe Shaolin::ContainerBuilder do
  include TmpApp

  it "auto-registers a component from a module folder by convention" do
    with_module("users", {
      "user_service.rb" => <<~RUBY
        module Users
          class UserService
            def call = :ok
          end
        end
      RUBY
    }) do |_root, mod_dir|
      container = described_class.build(name: "users", dir: mod_dir)
      expect(container["user_service"]).to be_a(Users::UserService)
      expect(container["user_service"].call).to eq(:ok)
    end
  end

  it "namespaces components under nested folders by key" do
    with_module("users", {
      "queries/find_user.rb" => <<~RUBY
        module Users
          module Queries
            class FindUser
              def call = :found
            end
          end
        end
      RUBY
    }) do |_root, mod_dir|
      container = described_class.build(name: "users", dir: mod_dir)
      expect(container["queries.find_user"].call).to eq(:found)
    end
  end
end

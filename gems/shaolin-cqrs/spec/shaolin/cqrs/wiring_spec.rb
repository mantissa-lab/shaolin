require "shaolin/cqrs"
require "tmpdir"
require "fileutils"

# Top-level command/event so the module's aggregate/handler/projection can
# reference them without intra-module load-order concerns (autoloading is
# verified separately in the demo app).
class RegisterUser
  attr_reader :id, :name
  def initialize(id:, name:) = (@id = id; @name = name)
end

class UserRegistered < RubyEventStore::Event; end
class FindUser; end

RSpec.describe "shaolin-cqrs auto-wiring" do
  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    $shaolin_wiring_seen = []
  end

  it "auto-registers handlers on the bus and subscribes projections" do
    Dir.mktmpdir do |root|
      dir = File.join(root, "app/modules/users")
      FileUtils.mkdir_p(File.join(dir, "command_handlers"))
      FileUtils.mkdir_p(File.join(dir, "query_handlers"))
      FileUtils.mkdir_p(File.join(dir, "projections"))

      File.write(File.join(dir, "module.rb"), 'Shaolin.module("users") {}')
      File.write(File.join(dir, "user.rb"), <<~RUBY)
        module Users
          class User
            include Shaolin::CQRS::Aggregate
            def register(name:) = apply(UserRegistered.new(data: { id: id, name: name }))
            on(UserRegistered) { |_e| }
          end
        end
      RUBY
      File.write(File.join(dir, "command_handlers/register_user_handler.rb"), <<~RUBY)
        require_relative "../user"

        module Users
          module CommandHandlers
            class RegisterUserHandler < Shaolin::CQRS::CommandHandler
              handles RegisterUser
              def call(cmd)
                aggregate_repository.unit_of_work(Users::User.new(cmd.id)) do |user|
                  user.register(name: cmd.name)
                end
              end
            end
          end
        end
      RUBY
      File.write(File.join(dir, "projections/users_projection.rb"), <<~RUBY)
        module Users
          module Projections
            class UsersProjection < Shaolin::CQRS::Projection
              on(UserRegistered) { |event| $shaolin_wiring_seen << event.data }
            end
          end
        end
      RUBY

      File.write(File.join(dir, "query_handlers/find_user_handler.rb"), <<~RUBY)
        module Users
          module QueryHandlers
            class FindUserHandler < Shaolin::CQRS::QueryHandler
              handles FindUser
              def call(_query) = $shaolin_wiring_seen.last
            end
          end
        end
      RUBY

      Shaolin::CQRS.register_provider!
      app = Shaolin::App.new(root: root).boot!

      app["users"]["cqrs.command_bus"].call(RegisterUser.new(id: "u1", name: "Jane"))

      expect($shaolin_wiring_seen).to eq([{ id: "u1", name: "Jane" }])
      expect(app["users"]["cqrs.query_bus"].call(FindUser.new)).to eq({ id: "u1", name: "Jane" })
    end
  end
end

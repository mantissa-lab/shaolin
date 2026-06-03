require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/dto"
require "shaolin/jobs"
require "shaolin/messaging"

# Two modules: `orders` (writes OrderPlaced) and `notifications` (a reactor that
# reacts to orders.order_placed BY TOPIC — cross-module, isolation-clean).
module CrossModuleExample
  ROOT = File.expand_path("..", __dir__)

  DATABASE = {
    adapter: "postgresql",
    database: ENV.fetch("DB_NAME", "shaolin_cross_example"),
    username: ENV.fetch("DB_USER", "postgres"),
    host: ENV.fetch("DB_HOST", "/tmp"),
    port: Integer(ENV.fetch("DB_PORT", "5433"))
  }.freeze

  def self.boot!
    Shaolin::AR.register_provider!(config: DATABASE)
    Shaolin::CQRS.register_provider!
    Shaolin::Jobs.register_provider!
    app = Shaolin::App.new(root: ROOT).boot!
    Shaolin::Kernel.register("messaging.publisher", Shaolin::Messaging::InMemoryPublisher.new)
    app
  end
end

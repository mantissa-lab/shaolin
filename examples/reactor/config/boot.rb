require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/jobs"
require "shaolin/messaging"

# A minimal shaolin app demonstrating async reactors over the transactional
# outbox: one `signups` module with a SignupCompleted event and a NotifyReactor
# that publishes an integration event. No HTTP, no read models — just the
# write side + the async runtime.
module ReactorExample
  ROOT = File.expand_path("..", __dir__)

  DATABASE = {
    adapter: "postgresql",
    database: ENV.fetch("DB_NAME", "shaolin_reactor_example"),
    username: ENV.fetch("DB_USER", "postgres"),
    host: ENV.fetch("DB_HOST", "/tmp"),
    port: Integer(ENV.fetch("DB_PORT", "5433"))
  }.freeze

  def self.boot!
    # persistence -> cqrs -> jobs. The :jobs provider wires each module's
    # reactors to the event store as transactional-outbox enqueuers.
    Shaolin::AR.register_provider!(config: DATABASE)
    Shaolin::CQRS.register_provider!
    Shaolin::Jobs.register_provider!

    app = Shaolin::App.new(root: ROOT).boot!

    # In a monolith the in-memory publisher is enough; flip to
    # Shaolin::RabbitMQ::Publisher to cross a service boundary (same port).
    Shaolin::Kernel.register("messaging.publisher", Shaolin::Messaging::InMemoryPublisher.new)
    app
  end
end

require "shaolin/core"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/dto"
require "shaolin/http"

# A shaolin demo app: a single `users` module wired as a CQRS/ES modular monolith
# over PostgreSQL, served by Falcon (via shaolin-server / `shaolin server`).
module Demo
  ROOT = File.expand_path("..", __dir__)

  DATABASE = {
    adapter: "postgresql",
    database: ENV.fetch("DB_NAME", "shaolin_demo"),
    username: ENV.fetch("DB_USER", "postgres"),
    host: ENV.fetch("DB_HOST", "/tmp"),
    port: Integer(ENV.fetch("DB_PORT", "5433"))
  }.freeze

  def self.boot!
    # Providers in dependency order: persistence -> cqrs -> http.
    Shaolin::AR.register_provider!(config: DATABASE)
    Shaolin::CQRS.register_provider!
    Shaolin::HTTP.register_provider!

    app = Shaolin::App.new(root: ROOT).boot!
    Shaolin::AR::Migrator.run(File.join(ROOT, "app/modules")) # read-model tables
    app
  end
end

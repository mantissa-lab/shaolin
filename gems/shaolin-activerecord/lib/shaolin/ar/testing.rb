require "active_record"

module Shaolin
  # Test isolation helpers (DatabaseCleaner-style, opt-in). `clean!` truncates
  # every app table — read models, the event store, AND the jobs outbox/schedules —
  # so integration examples don't accumulate rows across runs (a stale `pending`
  # outbox job firing in a later example was a real footgun). Excludes only AR's
  # own bookkeeping tables.
  #
  # Wire it once in spec_helper:
  #   Shaolin::Testing.install(config, only: :integration)
  module Testing
    PRESERVE = %w[schema_migrations ar_internal_metadata].freeze

    module_function

    def clean!
      conn = ::ActiveRecord::Base.connection
      tables = conn.tables - PRESERVE
      return if tables.empty?

      quoted = tables.map { |t| conn.quote_table_name(t) }.join(", ")
      conn.execute("TRUNCATE #{quoted} RESTART IDENTITY CASCADE")
    end

    # Register a before(:each) that cleans. `only:` scopes it to a tag (e.g.
    # :integration) so DB-less unit specs stay fast.
    def install(rspec_config, only: nil)
      filter = only ? { only => true } : {}
      rspec_config.before(:each, filter) { Shaolin::Testing.clean! }
    end
  end
end

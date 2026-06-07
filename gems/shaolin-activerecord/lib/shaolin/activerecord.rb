require_relative "activerecord/version"

module Shaolin
  module AR
    # ActiveRecord integration; components required as they are added.

    # Route a block's reads to the configured read replica (#27). No-op without a
    # replica, so query code can wrap heavy reads unconditionally:
    #   Shaolin::AR.reading { ReadModels::Big.where(stage: "offer").to_a }
    def self.reading(&block) = Connection.reading(&block)
  end
end
require_relative "ar/connection"
require_relative "ar/event_store_schema"
require_relative "ar/event_repository"
require_relative "ar/read_model"
require_relative "ar/migrator"
require_relative "ar/provider"
require_relative "ar/testing"

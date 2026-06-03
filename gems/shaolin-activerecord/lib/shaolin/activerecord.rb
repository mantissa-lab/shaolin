require_relative "activerecord/version"

module Shaolin
  module AR
    # ActiveRecord integration; components required as they are added.
  end
end
require_relative "ar/connection"
require_relative "ar/event_store_schema"
require_relative "ar/event_repository"
require_relative "ar/read_model"
require_relative "ar/migrator"
require_relative "ar/provider"

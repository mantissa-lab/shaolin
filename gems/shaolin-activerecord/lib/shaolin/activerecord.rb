require_relative "activerecord/version"

module Shaolin
  module AR
    # ActiveRecord integration; components required as they are added.
  end
end
require_relative "ar/connection"
require_relative "ar/event_store_schema"
require_relative "ar/event_repository"

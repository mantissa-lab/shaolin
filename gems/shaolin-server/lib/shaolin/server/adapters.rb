require "shaolin/core"
require_relative "adapters/puma"
require_relative "adapters/falcon"

module Shaolin
  module Server
    module Adapters
      def self.build(name)
        case name.to_sym
        when :puma   then Puma.new
        when :falcon then Falcon.new
        else raise Shaolin::Error, "unknown server adapter: #{name.inspect} (expected :falcon or :puma)"
        end
      end
    end
  end
end

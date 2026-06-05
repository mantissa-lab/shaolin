require "dry/inflector"

module Shaolin
  # THE inflector for shaolin — one source of truth so the generator's names, the
  # zeitwerk autoloader, and module namespaces all agree. Acronyms matter: without
  # a shared instance, `url_maps` became `UrlMaps` in the generator but `URLMaps`
  # in the autoloader → boot mismatch. (Migration class names are the one
  # exception: they follow ActiveRecord's plain camelize, via Naming#migration_class.)
  module Inflector
    ACRONYMS = %w[DTO ID API HTTP URL UUID UI].freeze

    module_function

    def instance
      @instance ||= Dry::Inflector.new { |i| ACRONYMS.each { |a| i.acronym(a) } }
    end

    def camelize(string)    = instance.camelize(string)
    def underscore(string)  = instance.underscore(string)
    def singularize(string) = instance.singularize(string)
    def pluralize(string)   = instance.pluralize(string)
  end
end

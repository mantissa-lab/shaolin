require_relative "errors"

module Shaolin
  # Lifecycle providers. Other gems (activerecord, cqrs, http, kafka, server)
  # plug into the kernel only through `Shaolin.register_provider`, declaring an
  # optional `after:` dependency list. Start runs in dependency order; stop runs
  # in reverse.
  class Provider
    Definition = Struct.new(:name, :after, :start_block, :stop_block, keyword_init: true)

    # Collects start/stop blocks from a provider's registration block.
    class DSL
      attr_reader :start_block, :stop_block

      def start(&blk) = (@start_block = blk)
      def stop(&blk)  = (@stop_block = blk)
    end

    @providers = {}

    class << self
      def register(name, after: [], &block)
        dsl = DSL.new
        dsl.instance_eval(&block) if block
        @providers[name] = Definition.new(
          name: name, after: Array(after),
          start_block: dsl.start_block, stop_block: dsl.stop_block
        )
      end

      # Topologically sorted provider definitions (dependencies first).
      def ordered
        resolved = []
        visiting = {}

        visit = lambda do |name|
          return if resolved.include?(name)
          raise BootError, "provider dependency cycle at '#{name}'" if visiting[name]

          definition = @providers[name]
          raise BootError, "unknown provider dependency '#{name}'" unless definition

          visiting[name] = true
          definition.after.each { |dep| visit.call(dep) }
          visiting[name] = false
          resolved << name
        end

        @providers.each_key { |name| visit.call(name) }
        resolved.map { |name| @providers[name] }
      end

      def start_all = ordered.each { |p| p.start_block&.call }
      def stop_all  = ordered.reverse_each { |p| p.stop_block&.call }
      def reset!    = (@providers = {})
    end
  end

  def self.register_provider(name, after: [], &block)
    Provider.register(name, after: after, &block)
  end
end

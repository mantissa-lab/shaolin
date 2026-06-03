require "prism"

module Shaolin
  module CLI
    # Static (no-boot) extraction of reactor + schedule declarations from source,
    # so `shaolin describe` can show the async surface of an app the same way it
    # shows commands/events. Pure Prism AST analysis.
    module StaticScan
      module_function

      # Reactors in a module dir: [{ class:, file:, on: [event consts] }, ...].
      # Picks up any `<Entity>Reactor`-style class with `on(EventConst) { ... }`.
      def reactors(module_dir)
        Dir.glob(File.join(module_dir, "reactors", "*.rb")).sort.flat_map do |file|
          result = Prism.parse_file(file)
          next [] unless result.success?

          v = ReactorVisitor.new
          result.value.accept(v)
          v.reactors.map { |r| r.merge(file: File.basename(file)) }
        end
      end

      # Scheduled tasks under a tree: [{ name:, every: }, ...] from
      # `Shaolin.schedule("name", every: "5m")` calls anywhere in the sources.
      def schedules(*roots)
        roots.flat_map do |root|
          Dir.glob(File.join(root, "**", "*.rb")).sort.flat_map do |file|
            result = Prism.parse_file(file)
            next [] unless result.success?

            v = ScheduleVisitor.new
            result.value.accept(v)
            v.schedules
          end
        end
      end

      # Collects `class Foo < ...` names and the `on(Const)` subscriptions inside.
      class ReactorVisitor < Prism::Visitor
        attr_reader :reactors

        def initialize
          super
          @reactors = []
          @current = nil
        end

        def visit_class_node(node)
          prev = @current
          # `on:` = own-module event classes; `topics:` = cross-module topic strings
          @current = { class: const_name(node.constant_path), on: [], topics: [] }
          @reactors << @current
          super
          @current = prev
        end

        def visit_call_node(node)
          if @current && node.name == :on && node.receiver.nil?
            arg = node.arguments&.arguments&.first
            if arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)
              @current[:on] << const_name(arg)
            elsif arg.is_a?(Prism::StringNode)
              @current[:topics] << arg.unescaped
            end
          end
          super
        end

        private

        def const_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then node.full_name
          else node.to_s
          end
        end
      end

      # Collects `Shaolin.schedule("name", every: "5m")` calls.
      class ScheduleVisitor < Prism::Visitor
        attr_reader :schedules

        def initialize
          super
          @schedules = []
        end

        def visit_call_node(node)
          recv = node.receiver
          if node.name == :schedule && recv.is_a?(Prism::ConstantReadNode) && recv.name == :Shaolin
            name_arg = node.arguments&.arguments&.first
            name = name_arg.is_a?(Prism::StringNode) ? name_arg.unescaped : nil
            @schedules << { name: name, every: every_arg(node) } if name
          end
          super
        end

        private

        def every_arg(node)
          kw = node.arguments&.arguments&.find { |a| a.is_a?(Prism::KeywordHashNode) }
          pair = kw&.elements&.grep(Prism::AssocNode)&.find { |e| key_name(e.key) == "every" }
          val = pair&.value
          val.is_a?(Prism::StringNode) ? val.unescaped : nil
        end

        def key_name(key)
          case key
          when Prism::SymbolNode then key.unescaped
          when Prism::StringNode then key.unescaped
          end
        end
      end
    end
  end
end

require "prism"
require_relative "naming"

module Shaolin
  module CLI
    # Static isolation check: a module folder must be ownable in isolation, so it
    # may not reach into another module's internals. Flags (a) references to
    # another module's top-level namespace constant, and (b) `require_relative`
    # that escapes the module's own folder. Pure AST analysis (Prism) — no boot.
    class Isolation
      Violation = Struct.new(:file, :line, :rule, :message) do
        def to_s = "#{file}:#{line}  #{rule}: #{message}"
      end

      def initialize(modules_dir)
        @modules_dir = modules_dir
        @module_dirs = Dir.glob(File.join(modules_dir, "*")).select { |d| File.directory?(d) }
        @namespaces = @module_dirs.to_h { |d| [File.basename(d), Naming.namespace(File.basename(d))] }
      end

      def violations
        @module_dirs.flat_map do |dir|
          own_ns = @namespaces[File.basename(dir)]
          others = @namespaces.values - [own_ns]
          declared = declared_imports(dir)
          Dir.glob(File.join(dir, "**", "*.rb")).flat_map { |file| scan(file, dir, others, declared) }
        end
      end

      private

      def scan(file, dir, others, declared)
        result = Prism.parse_file(file)
        return [] unless result.success?

        walker = Walker.new
        result.value.accept(walker)
        rel = relative(file)
        found = []

        walker.constants.uniq.each do |root, line|
          next unless others.include?(root)

          found << Violation.new(rel, line, "cross-module-reference",
                                 "references another module's namespace `#{root}` (use imports/exports)")
        end

        walker.requires.uniq.each do |path, line|
          resolved = File.expand_path(path, File.dirname(file))
          next if resolved.start_with?("#{File.expand_path(dir)}/")

          found << Violation.new(rel, line, "require-escapes-module",
                                 "require_relative escapes the module folder: #{path}")
        end

        walker.imports.uniq.each do |key, line|
          next if declared.include?(key)

          found << Violation.new(rel, line, "undeclared-import",
                                 "import(#{key.inspect}) is not declared in module.rb (add `imports #{key.inspect}`)")
        end

        found
      end

      # Strings declared in this module's manifest via `imports "..."` and
      # `imports events: [...]` — the allow-list for `import("...")` calls.
      def declared_imports(dir)
        manifest = File.join(dir, "module.rb")
        return [] unless File.file?(manifest)

        result = Prism.parse_file(manifest)
        return [] unless result.success?

        walker = ManifestWalker.new
        result.value.accept(walker)
        walker.declared
      end

      def relative(file) = file.sub("#{File.expand_path(@modules_dir)}/", "")

      # Collects the import keys declared in a module.rb manifest.
      class ManifestWalker < Prism::Visitor
        def initialize
          super
          @declared = []
        end

        attr_reader :declared

        def visit_call_node(node)
          if node.name == :imports
            args = node.arguments&.arguments || []
            args.each do |arg|
              @declared << arg.unescaped if arg.is_a?(Prism::StringNode)
              next unless arg.is_a?(Prism::KeywordHashNode)

              arg.elements.grep(Prism::AssocNode).each do |pair|
                pair.value.elements.each { |e| @declared << e.unescaped if e.is_a?(Prism::StringNode) } if pair.value.is_a?(Prism::ArrayNode)
              end
            end
          end
          super
        end
      end

      # Collects root constant names (+ line) and require_relative paths (+ line).
      class Walker < Prism::Visitor
        def initialize
          @constants = []
          @requires = []
          @imports = []
        end

        attr_reader :constants, :requires, :imports

        def visit_constant_path_node(node)
          @constants << [root_name(node), node.location.start_line]
          super
        end

        def visit_call_node(node)
          arg = node.arguments&.arguments&.first
          if node.name == :require_relative && arg.is_a?(Prism::StringNode)
            @requires << [arg.unescaped, node.location.start_line]
          elsif node.name == :import && node.receiver.nil? && arg.is_a?(Prism::StringNode)
            @imports << [arg.unescaped, node.location.start_line]
          end
          super
        end

        private

        def root_name(node)
          n = node
          n = n.parent while n.is_a?(Prism::ConstantPathNode) && n.parent
          n.respond_to?(:name) ? n.name.to_s : n.to_s
        end
      end
    end
  end
end

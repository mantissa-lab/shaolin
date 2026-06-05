require "prism"
require "json"

module Shaolin
  module CLI
    # Builds an OpenAPI 3.1 document from a BOOTED app: paths/methods/params from
    # each controller's route_set, request-body schemas from the DTO each action
    # validates (linked by a static scan of the controller for `SomeDTO.validate`,
    # then dry-schema's :json_schema extension), and the standard status codes +
    # error schema from shaolin's Result→HTTP contract. Response bodies are left
    # generic in v1. OpenAPI 3.1 is used because it aligns with JSON Schema, so the
    # DTO schemas drop in directly.
    module OpenAPI
      ERROR_SCHEMA = {
        "type" => "object",
        "properties" => {
          "error" => {
            "type" => "object",
            "properties" => { "code" => { "type" => "string" }, "message" => { "type" => "string" } }
          }
        }
      }.freeze

      module_function

      def generate(containers, modules_dir, title: "API")
        require "dry/schema"
        Dry::Schema.load_extensions(:json_schema)
        schemas = { "Error" => ERROR_SCHEMA.dup }
        paths = {}

        containers.each do |module_name, container|
          container.keys.grep(%r{\Acontrollers\.}).each do |key|
            controller = container[key]
            namespace = controller.class.name.split("::").first
            action_dtos = scan_action_dtos(modules_dir, module_name)

            controller.class.route_set.each do |route|
              op = operation(route, action_dtos, namespace, schemas)
              (paths[openapi_path(route[:path])] ||= {})[route[:method].to_s] = op
            end
          end
        end

        { "openapi" => "3.1.0", "info" => { "title" => title, "version" => "1.0.0" },
          "paths" => paths, "components" => { "schemas" => schemas } }
      end

      # def <action> ... SomeDTO.validate(...) -> { "create" => "DTO::CreatePostDTO" }
      def scan_action_dtos(modules_dir, module_name)
        mapping = {}
        Dir.glob(File.join(modules_dir, module_name, "controllers", "*.rb")).each do |file|
          result = Prism.parse_file(file)
          next unless result.success?

          v = ActionDTOScanner.new
          result.value.accept(v)
          mapping.merge!(v.action_dtos)
        end
        mapping
      end

      def operation(route, action_dtos, namespace, schemas)
        action = route[:action].to_s
        op = { "operationId" => "#{namespace}_#{action}", "parameters" => path_params(route[:path]) }
        op.delete("parameters") if op["parameters"].empty?
        op["responses"] = { "200" => { "description" => "OK" } }

        dto_const = action_dtos[action]
        if dto_const && %w[post put patch].include?(route[:method].to_s)
          schema_name = register_dto(dto_const, namespace, schemas)
          if schema_name
            op["requestBody"] = {
              "required" => true,
              "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/#{schema_name}" } } }
            }
            op["responses"]["422"] = error_response("validation failed")
          end
        end
        op
      end

      def register_dto(dto_const, namespace, schemas)
        klass = resolve(dto_const, namespace) or return nil

        name = klass.name.split("::").last
        # dry-schema's json_schema returns symbol keys; stringify (JSON round-trip)
        # so the whole document is uniformly string-keyed.
        schema = JSON.parse(JSON.generate(klass.schema.json_schema))
        schema.delete("$schema")
        schemas[name] ||= schema
        name
      rescue StandardError
        nil
      end

      def resolve(const_name, namespace)
        Object.const_get(const_name)
      rescue NameError
        Object.const_get("#{namespace}::#{const_name}")
      rescue NameError
        nil
      end

      def openapi_path(path) = path.gsub(/:(\w+)/, '{\1}')

      def path_params(path)
        path.scan(/:(\w+)/).flatten.map do |name|
          { "name" => name, "in" => "path", "required" => true, "schema" => { "type" => "string" } }
        end
      end

      def error_response(desc)
        { "description" => desc,
          "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Error" } } } }
      end

      # Collects `def <name> ... <Const>.validate(...)` -> { name => const }.
      class ActionDTOScanner < Prism::Visitor
        attr_reader :action_dtos

        def initialize
          super
          @action_dtos = {}
          @current = nil
        end

        def visit_def_node(node)
          prev = @current
          @current = node.name.to_s
          super
          @current = prev
        end

        def visit_call_node(node)
          if @current && node.name == :validate && node.receiver
            const = const_name(node.receiver)
            @action_dtos[@current] ||= const if const&.match?(/DTO\z/i)
          end
          super
        end

        private

        def const_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then node.full_name
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end

require "shaolin/http"
require "securerandom"
require_relative "../commands/register_user"
require_relative "../read_models/user_record"
require_relative "../dto/register_user_dto"

module Users
  module Controllers
    class UsersController < Shaolin::HTTP::Controller
      routes do
        post "/users",     :create
        get  "/users/:id", :show
      end

      # Write side: validate -> command -> (aggregate emits event -> projection).
      def create(req)
        dto = DTO::RegisterUserDTO.validate(req.params)
        return unprocessable(dto.errors) if dto.failure?

        id = SecureRandom.uuid
        result = command_bus.call(Commands::RegisterUser.new(id: id, **dto.to_h))
        render_result(result, location: "/users/#{id}")
      end

      # Read side: query the projection (read model).
      def show(req)
        record = ReadModels::UserRecord.find_by(id: req[:id])
        return not_found("user #{req[:id]} not found") unless record

        json({ id: record.id, name: record.name, email: record.email })
      end
    end
  end
end

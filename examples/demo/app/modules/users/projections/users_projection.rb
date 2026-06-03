require "shaolin/cqrs"
require_relative "../events/user_registered"
require_relative "../read_models/user_record"

module Users
  module Projections
    class UsersProjection < Shaolin::CQRS::Projection
      on(Events::UserRegistered) do |event|
        ReadModels::UserRecord.project(id: event.data[:id]) do |record|
          record.name = event.data[:name]
          record.email = event.data[:email]
        end
      end
    end
  end
end

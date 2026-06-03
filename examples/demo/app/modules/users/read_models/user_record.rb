require "shaolin/activerecord"

module Users
  module ReadModels
    class UserRecord < Shaolin::AR::ReadModel
      self.table_name = "users_read"
    end
  end
end

class CreateUsersRead < ActiveRecord::Migration[8.0]
  def change
    create_table(:users_read, id: :string) do |t|
      t.string :name
      t.string :email
    end
  end
end

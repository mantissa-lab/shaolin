Shaolin.module "users" do
  commands_handled "Users::Commands::RegisterUser"
  events_published "users.user_registered"
end

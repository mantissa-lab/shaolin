$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "shaolin/llm"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!

  # Live LLM tests hit the network — opt in with RUN_LIVE=1 (or --tag live).
  config.filter_run_excluding(:live) unless ENV["RUN_LIVE"]
end

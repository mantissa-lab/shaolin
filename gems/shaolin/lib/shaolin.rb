require "shaolin/version"

# The umbrella entrypoint. `require "shaolin"` loads the whole framework, the way
# `require "rails"` does — so an app's boot needs a single require instead of one
# per sub-gem. Each sub-gem still requires its own dependencies, so the order
# here only needs to put the kernel (core) first.
#
# `shaolin-cli` is intentionally NOT required: it's the `shaolin` command-line
# tool (Thor + Prism), needed to scaffold/lint/run — not at application runtime.
# The umbrella still DEPENDS on it, so the `shaolin` binary is installed.
require "shaolin/core"
require "shaolin/dto"
require "shaolin/cqrs"
require "shaolin/activerecord"
require "shaolin/http"
require "shaolin/server"
require "shaolin/messaging"
require "shaolin/jobs"
require "shaolin/redis"
require "shaolin/rabbitmq"
require "shaolin/llm"
require "shaolin/harness"

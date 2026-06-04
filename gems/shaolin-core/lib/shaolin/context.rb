module Shaolin
  # The blessed channel for request-scoped values to flow from middleware to
  # controllers (and into logs). A generic fiber/thread-local key-value bag —
  # where Shaolin::Tenant carries just the tenant, Context carries anything an
  # auth/middleware layer resolves (e.g. the project_id behind an API key).
  #
  #   # in middleware:
  #   Shaolin::Context[:project_id] = resolve(env["HTTP_AUTHORIZATION"])
  #   # in a controller action:
  #   project_id = Shaolin::Context[:project_id]
  #
  # The HTTP layer clears it at the end of each request, so values never leak
  # across requests on a reused fiber/thread. Values are also merged into every
  # Shaolin::Log record for free correlation.
  module Context
    KEY = :shaolin_context

    module_function

    def store = (Thread.current[KEY] ||= {})
    def [](key) = store[key]

    def []=(key, value)
      store[key] = value
    end

    def to_h = store.dup
    def clear = (Thread.current[KEY] = {})

    def with(**fields)
      previous = store.dup
      store.merge!(fields)
      yield
    ensure
      Thread.current[KEY] = previous
    end
  end
end

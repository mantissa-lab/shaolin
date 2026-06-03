module Shaolin
  # Multi-tenancy context. shaolin does not impose tenant isolation — stream
  # names, aggregate ids, and read-model tables are app-defined — but apps that
  # serve many tenants need a request/job-scoped "current tenant" to scope ids,
  # stream prefixes, and read-model queries. This holds it per fiber/thread.
  #
  # Set it in HTTP middleware (from a header / JWT claim) and in reactors (from
  # the event's data), then weave it into your aggregate ids / read-model columns
  # and always filter reads by it. Isolation is enforced by YOUR code using this
  # value — the framework only carries it. (Thread.current is fiber-local under
  # Falcon's fiber scheduler, so it is correct for both server models.)
  module Tenant
    KEY = :shaolin_current_tenant

    module_function

    def current = Thread.current[KEY]

    def current=(id)
      Thread.current[KEY] = id
    end

    # Run a block with the tenant set, restoring the previous value after.
    def with(id)
      previous = current
      self.current = id
      yield
    ensure
      self.current = previous
    end
  end
end

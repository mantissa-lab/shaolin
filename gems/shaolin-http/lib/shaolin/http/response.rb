module Shaolin
  module HTTP
    # An immutable-per-action HTTP response (issue #13). Controller helpers
    # (`json`/`text`/`created`/…) return one of these; the router renders it to a
    # Rack tuple. It carries no shared/request-spanning state (a fresh object per
    # action call), so it's fiber-safe under Falcon — unlike a mutable `response`
    # accessor that would need fiber-local storage. Chainable `#cookie`/`#header`
    # return self. Back-compat: `to_ary` lets it destructure as `[status, headers,
    # body]`, and the router also accepts a raw Rack tuple returned from an action.
    class Response
      attr_reader :status, :headers, :body

      def initialize(status, headers = {}, body = [])
        @status = status
        @headers = headers
        @cookies = []
        @body = body
      end

      def header(key, value)
        @headers[key] = value
        self
      end

      # Set a cookie with sane secure defaults (HttpOnly + SameSite=Lax + Secure).
      # `delete_cookie` expires it (Max-Age=0, no Secure so it clears over http too).
      def cookie(name, value, path: "/", max_age: nil, http_only: true, same_site: :lax, secure: true, domain: nil)
        parts = ["#{name}=#{value}", "Path=#{path}"]
        parts << "Max-Age=#{max_age}" unless max_age.nil?
        parts << "Domain=#{domain}" if domain
        parts << "HttpOnly" if http_only
        parts << "Secure" if secure
        parts << "SameSite=#{same_site.to_s.capitalize}" if same_site
        @cookies << parts.join("; ")
        self
      end

      def delete_cookie(name, path: "/")
        cookie(name, "", path: path, max_age: 0, http_only: true, secure: false)
      end

      # Apply a `{ name => "value" | { value:, **opts } }` cookies hash (the
      # `json(..., cookies:)` keyword form).
      def cookies(map)
        map.each do |name, spec|
          spec.is_a?(Hash) ? cookie(name, spec[:value], **spec.except(:value)) : cookie(name, spec)
        end
        self
      end

      def to_rack
        headers = @headers.dup
        headers["set-cookie"] = @cookies.size == 1 ? @cookies.first : @cookies unless @cookies.empty?
        [@status, headers, @body]
      end
      alias to_a to_rack
      alias to_ary to_rack
    end
  end
end

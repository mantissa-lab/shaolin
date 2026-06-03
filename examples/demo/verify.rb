require_relative "config/boot"
require "rack/test"
require "json"

Demo.boot!
app = Shaolin::Kernel["http.app"]
session = Rack::Test::Session.new(app)

def show(session, label)
  r = session.last_response
  puts "#{label} -> #{r.status} #{r.headers['location']} #{r.body}"
  r
end

puts "== healthz =="
session.get("/healthz")
show(session, "GET /healthz")

puts "\n== register a user (write: command -> event -> projection) =="
session.post("/users", JSON.generate(name: "Jane Doe", email: "jane@doe.org"), "CONTENT_TYPE" => "application/json")
location = show(session, "POST /users").headers["location"]

puts "\n== read it back (read: query the projection) =="
session.get(location)
body = show(session, "GET #{location}").body
parsed = JSON.parse(body)
raise "read model mismatch: #{parsed.inspect}" unless parsed["name"] == "Jane Doe" && parsed["email"] == "jane@doe.org"

puts "\n== validation failure (422) =="
session.post("/users", JSON.generate(name: "", email: "nope"), "CONTENT_TYPE" => "application/json")
raise "expected 422" unless show(session, "POST invalid").status == 422

puts "\n== missing user (404) =="
session.get("/users/does-not-exist")
raise "expected 404" unless show(session, "GET missing").status == 404

puts "\n✅ shaolin demo end-to-end OK (command -> event(Postgres) -> projection -> query, over HTTP)"

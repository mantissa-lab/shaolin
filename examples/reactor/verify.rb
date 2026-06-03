require_relative "config/boot"
require "shaolin/jobs"

ReactorExample.boot!

event_store = Shaolin::Kernel["cqrs.event_store"]
outbox      = Shaolin::Kernel["jobs.outbox"]
publisher   = Shaolin::Kernel["messaging.publisher"]

# Clean slate so the script is repeatable.
Shaolin::Jobs::OutboxJob.delete_all

puts "== append a domain event (as an aggregate would) =="
event = Signups::Events::SignupCompleted.new(data: { id: "u-1", email: "neo@matrix.io" })
event_store.publish(event, stream_name: "Signups$u-1")
puts "published SignupCompleted #{event.event_id}"

puts "\n== assert the outbox row was written in the same transaction =="
pending = Shaolin::Jobs::OutboxJob.where(status: "pending").count
puts "pending outbox jobs: #{pending}"
raise "expected 1 pending outbox job, got #{pending}" unless pending == 1
raise "reactor must not have run yet" unless publisher.published.empty?

puts "\n== run the worker once (this is what `shaolin worker` loops) =="
worker = Shaolin::Jobs::Worker.new(event_store: event_store, outbox: outbox)
worker.run_once

puts "\n== assert the reactor side effect happened and the job is done =="
published = publisher.published
puts "integration events published: #{published.size}"
raise "expected 1 published integration event" unless published.size == 1

ie = published.first
raise "wrong event_type: #{ie.event_type}" unless ie.event_type == "signups.signup_completed"
raise "wrong payload: #{ie.payload.inspect}" unless ie.payload == { id: "u-1", email: "neo@matrix.io" }

done = Shaolin::Jobs::OutboxJob.where(status: "done").count
puts "done outbox jobs: #{done}"
raise "expected the outbox job to be marked done" unless done == 1

puts "\n✅ shaolin reactor end-to-end OK"
puts "   (event -> transactional outbox row -> shaolin worker -> reactor publishes integration event)"

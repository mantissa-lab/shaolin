require "shaolin/jobs"
require "support/pg"
require "tmpdir"
require "fileutils"

class CreateThing
  attr_reader :id
  def initialize(id:) = (@id = id)
end
class ThingMade < RubyEventStore::Event; end

RSpec.describe Shaolin::Jobs::Worker do
  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    PgTest.reset_schema!
    $worker_seen = Queue.new
    $boom = false
  end

  def boot(root)
    dir = File.join(root, "app/modules/things")
    FileUtils.mkdir_p(File.join(dir, "command_handlers"))
    FileUtils.mkdir_p(File.join(dir, "reactors"))
    File.write(File.join(dir, "module.rb"), 'Shaolin.module("things") {}')
    File.write(File.join(dir, "thing.rb"), <<~RUBY)
      module Things
        class Thing
          include Shaolin::CQRS::Aggregate
          def make = apply(ThingMade.new(data: { id: id }))
          on(ThingMade) { |_e| }
        end
      end
    RUBY
    File.write(File.join(dir, "command_handlers/create_thing_handler.rb"), <<~RUBY)
      module Things
        module CommandHandlers
          class CreateThingHandler < Shaolin::CQRS::CommandHandler
            handles CreateThing
            def call(cmd) = aggregate_repository.unit_of_work(Things::Thing.new(cmd.id)) { |t| t.make }
          end
        end
      end
    RUBY
    File.write(File.join(dir, "reactors/thing_reactor.rb"), <<~RUBY)
      module Things
        module Reactors
          class ThingReactor < Shaolin::Jobs::Reactor
            on(ThingMade) do |event|
              raise "boom" if $boom
              $worker_seen << event.data[:id]
            end
          end
        end
      end
    RUBY

    Shaolin::AR.register_provider!(config: PgTest::CONFIG)
    Shaolin::CQRS.register_provider!
    Shaolin::Jobs.register_provider!
    Shaolin::App.new(root: root).boot!
  end

  it "#2 claims a pending job, runs the reactor, marks it done" do
    Dir.mktmpdir do |root|
      app = boot(root)
      app["things"]["cqrs.command_bus"].call(CreateThing.new(id: "t1"))

      processed = described_class.new(event_store: Shaolin::Kernel["cqrs.event_store"]).run_once
      expect(processed).to eq(1)
      expect($worker_seen.size).to eq(1)
      expect(Shaolin::Jobs::OutboxJob.first.status).to eq("done")
    end
  end

  it "#3 retries a failing reactor with backoff, then dead-letters it" do
    Dir.mktmpdir do |root|
      app = boot(root)
      $boom = true
      app["things"]["cqrs.command_bus"].call(CreateThing.new(id: "t2"))

      worker = described_class.new(event_store: Shaolin::Kernel["cqrs.event_store"], backoff: [0, 0], max_attempts: 2)

      worker.run_once(now: Time.now)
      job = Shaolin::Jobs::OutboxJob.first
      expect(job.reload.status).to eq("failed")
      expect(job.attempts).to eq(1)

      worker.run_once(now: Time.now + 1)
      expect(job.reload.status).to eq("dead")
      expect(job.attempts).to eq(2)
      expect(Shaolin::Jobs::OutboxJob.count).to eq(1) # kept for inspection
    end
  end

  it "#4 two concurrent workers never run the same job twice (SKIP LOCKED)" do
    Dir.mktmpdir do |root|
      app = boot(root)
      bus = app["things"]["cqrs.command_bus"]
      6.times { |i| bus.call(CreateThing.new(id: "id#{i}")) }

      threads = Array.new(2) do
        Thread.new do
          worker = described_class.new(event_store: Shaolin::Kernel["cqrs.event_store"], batch: 1)
          20.times { break if worker.run_once.zero? }
        end
      end
      threads.each(&:join)

      processed = []
      processed << $worker_seen.pop until $worker_seen.empty?
      expect(processed.sort).to eq(%w[id0 id1 id2 id3 id4 id5])      # all
      expect(processed.uniq.size).to eq(processed.size)              # none twice
      expect(Shaolin::Jobs::OutboxJob.where(status: "done").count).to eq(6)
    end
  end

  it "run drains on a thread pool and stops gracefully on stop!" do
    Dir.mktmpdir do |root|
      app = boot(root)
      app["things"]["cqrs.command_bus"].call(CreateThing.new(id: "g1"))

      worker = described_class.new(event_store: Shaolin::Kernel["cqrs.event_store"])
      t = Thread.new { worker.run(poll_interval: 0.01, threads: 2) }
      sleep 0.1
      worker.stop!

      expect(t.join(3)).not_to be_nil               # pool drained + terminated promptly
      expect($worker_seen.size).to eq(1)            # the job was processed by the pool
      expect(Shaolin::Jobs::OutboxJob.first.status).to eq("done")
    end
  end

  it "tx_per_job mode commits each job independently and respects the batch bound" do
    Dir.mktmpdir do |root|
      app = boot(root)
      bus = app["things"]["cqrs.command_bus"]
      5.times { |i| bus.call(CreateThing.new(id: "p#{i}")) }

      worker = described_class.new(event_store: Shaolin::Kernel["cqrs.event_store"], batch: 2, tx_per_job: true)
      expect(worker.run_once).to eq(2)                                   # bounded by batch
      expect(Shaolin::Jobs::OutboxJob.where(status: "done").count).to eq(2)
      expect(Shaolin::Jobs::OutboxJob.where(status: "pending").count).to eq(3)

      worker.run_once
      worker.run_once
      expect(Shaolin::Jobs::OutboxJob.where(status: "done").count).to eq(5) # rest drained
    end
  end
end

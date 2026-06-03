require "shaolin/jobs"
require "support/pg"
require "tmpdir"
require "fileutils"

# Top-level command (module A's handler references it at load time).
class RecordConversion
  attr_reader :id
  def initialize(id:) = (@id = id)
end

RSpec.describe "cross-module reactor (topic subscription)" do
  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    PgTest.reset_schema!
    $cross_seen = Queue.new
  end

  # Module A "conversions" publishes Conversions::Events::ConversionRecorded;
  # module B "dispatches" reacts to it BY TOPIC STRING (no reference to A's class),
  # declaring the topic in its manifest's imports(events:).
  def build_app(root)
    a = File.join(root, "app/modules/conversions")
    FileUtils.mkdir_p(File.join(a, "events"))
    FileUtils.mkdir_p(File.join(a, "command_handlers"))
    File.write(File.join(a, "module.rb"), 'Shaolin.module("conversions") { events_published "conversions.conversion_recorded" }')
    File.write(File.join(a, "events/conversion_recorded.rb"), <<~RUBY)
      module Conversions
        module Events
          class ConversionRecorded < RubyEventStore::Event; end
        end
      end
    RUBY
    File.write(File.join(a, "conversion.rb"), <<~RUBY)
      module Conversions
        class Conversion
          include Shaolin::CQRS::Aggregate
          def record = apply(Conversions::Events::ConversionRecorded.new(data: { id: id }))
          on(Conversions::Events::ConversionRecorded) { |_e| }
        end
      end
    RUBY
    File.write(File.join(a, "command_handlers/record_conversion_handler.rb"), <<~RUBY)
      module Conversions
        module CommandHandlers
          class RecordConversionHandler < Shaolin::CQRS::CommandHandler
            handles RecordConversion
            def call(cmd)
              aggregate_repository.unit_of_work(Conversions::Conversion.new(cmd.id)) { |c| c.record }
            end
          end
        end
      end
    RUBY

    b = File.join(root, "app/modules/dispatches")
    FileUtils.mkdir_p(File.join(b, "reactors"))
    File.write(File.join(b, "module.rb"), <<~RUBY)
      Shaolin.module("dispatches") do
        imports events: ["conversions.conversion_recorded"]
      end
    RUBY
    File.write(File.join(b, "reactors/conversion_dispatcher.rb"), <<~RUBY)
      module Dispatches
        module Reactors
          class ConversionDispatcher < Shaolin::Jobs::Reactor
            on("conversions.conversion_recorded") { |event| $cross_seen << event.data[:id] }
          end
        end
      end
    RUBY

    Shaolin::AR.register_provider!(config: PgTest::CONFIG)
    Shaolin::CQRS.register_provider!
    Shaolin::Jobs.register_provider!
    Shaolin::App.new(root: root).boot!
  end

  it "#1 enqueues an outbox job for B atomically when A publishes the event" do
    Dir.mktmpdir do |root|
      app = build_app(root)
      bus = app["conversions"]["cqrs.command_bus"]

      bus.call(RecordConversion.new(id: "c1"))

      job = Shaolin::Jobs::OutboxJob.where(status: "pending").first
      expect(job).not_to be_nil
      expect(job.reactor).to eq("Dispatches::Reactors::ConversionDispatcher")
      expect(job.event_type).to eq("Conversions::Events::ConversionRecorded")

      # rolled-back dispatch leaves no job (atomic with the event append)
      ActiveRecord::Base.transaction do
        bus.call(RecordConversion.new(id: "c2"))
        raise ActiveRecord::Rollback
      end
      expect(Shaolin::Jobs::OutboxJob.where(event_id: nil).count).to eq(0)
      expect(Shaolin::Jobs::OutboxJob.count).to eq(1)
    end
  end

  it "#2 worker runs B's reactor with the reconstructed A event" do
    Dir.mktmpdir do |root|
      build_app(root)
      Shaolin::Kernel["cqrs.command_bus"].call(RecordConversion.new(id: "c1"))

      worker = Shaolin::Jobs::Worker.new(event_store: Shaolin::Kernel["cqrs.event_store"])
      worker.run_once

      expect($cross_seen.size).to eq(1)
      expect($cross_seen.pop).to eq("c1")
      expect(Shaolin::Jobs::OutboxJob.where(status: "done").count).to eq(1)
    end
  end
end

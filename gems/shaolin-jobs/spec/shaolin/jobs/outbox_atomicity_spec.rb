require "shaolin/jobs"
require "support/pg"
require "tmpdir"
require "fileutils"

# Top-level command/event so the module files reference them without intra-module
# autoload concerns (mirrors the cqrs wiring spec).
class CreateWidget
  attr_reader :id, :name
  def initialize(id:, name:) = (@id = id; @name = name)
end
class WidgetMade < RubyEventStore::Event; end

RSpec.describe "transactional outbox (acceptance #1)" do
  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    PgTest.reset_schema!
  end

  def build_app(root)
    dir = File.join(root, "app/modules/widgets")
    FileUtils.mkdir_p(File.join(dir, "command_handlers"))
    FileUtils.mkdir_p(File.join(dir, "reactors"))

    File.write(File.join(dir, "module.rb"), 'Shaolin.module("widgets") {}')
    File.write(File.join(dir, "widget.rb"), <<~RUBY)
      module Widgets
        class Widget
          include Shaolin::CQRS::Aggregate
          def make(name:) = apply(WidgetMade.new(data: { id: id, name: name }))
          on(WidgetMade) { |_e| }
        end
      end
    RUBY
    File.write(File.join(dir, "command_handlers/create_widget_handler.rb"), <<~RUBY)
      module Widgets
        module CommandHandlers
          class CreateWidgetHandler < Shaolin::CQRS::CommandHandler
            handles CreateWidget
            def call(cmd)
              aggregate_repository.unit_of_work(Widgets::Widget.new(cmd.id)) { |w| w.make(name: cmd.name) }
            end
          end
        end
      end
    RUBY
    File.write(File.join(dir, "reactors/widget_reactor.rb"), <<~RUBY)
      module Widgets
        module Reactors
          class WidgetReactor < Shaolin::Jobs::Reactor
            on(WidgetMade) { |_event| } # side effect runs in the worker (phase 2)
          end
        end
      end
    RUBY

    Shaolin::AR.register_provider!(config: PgTest::CONFIG)
    Shaolin::CQRS.register_provider!
    Shaolin::Jobs.register_provider!
    Shaolin::App.new(root: root).boot!
  end

  it "enqueues exactly one outbox job atomically with the event, and none on rollback" do
    Dir.mktmpdir do |root|
      app = build_app(root)
      bus = app["widgets"]["cqrs.command_bus"]

      # committed dispatch -> one pending job
      bus.call(CreateWidget.new(id: "w1", name: "A"))
      expect(Shaolin::Jobs::OutboxJob.where(status: "pending").count).to eq(1)
      job = Shaolin::Jobs::OutboxJob.first
      expect(job.reactor).to eq("Widgets::Reactors::WidgetReactor")
      expect(job.event_type).to eq("WidgetMade")

      # rolled-back dispatch -> no new job (and no new event)
      events_before = Shaolin::Jobs::OutboxJob.count
      ActiveRecord::Base.transaction do
        bus.call(CreateWidget.new(id: "w2", name: "B"))
        raise ActiveRecord::Rollback
      end
      expect(Shaolin::Jobs::OutboxJob.count).to eq(events_before)
    end
  end

  it "is atomic by DEFAULT: a failing sync subscriber rolls back the event AND the outbox (no manual transaction)" do
    Dir.mktmpdir do |root|
      app = build_app(root)
      bus = app["widgets"]["cqrs.command_bus"]
      event_store = Shaolin::Kernel["cqrs.event_store"]
      # a synchronous subscriber that blows up mid-append (e.g. a projection bug)
      event_store.subscribe(->(_e) { raise "sync boom" }, to: [WidgetMade])

      expect { bus.call(CreateWidget.new(id: "w9", name: "Z")) }.to raise_error(/sync boom/)

      # the framework wrapped the unit of work in a transaction, so NOTHING persisted
      expect(Shaolin::Jobs::OutboxJob.count).to eq(0)
      expect(event_store.read.of_type([WidgetMade]).to_a).to be_empty
    end
  end

  it "enqueues idempotently: re-publishing the same event does not duplicate the outbox row" do
    Dir.mktmpdir do |root|
      build_app(root)
      outbox = Shaolin::Kernel["jobs.outbox"]
      event = WidgetMade.new(data: { id: "w1", name: "A" })

      outbox.enqueue(reactor: "Widgets::Reactors::WidgetReactor", event: event)
      outbox.enqueue(reactor: "Widgets::Reactors::WidgetReactor", event: event) # same event_id

      expect(Shaolin::Jobs::OutboxJob.where(event_id: event.event_id).count).to eq(1)
    end
  end
end

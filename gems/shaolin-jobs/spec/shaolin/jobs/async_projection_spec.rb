require "shaolin/jobs"
require "support/pg"
require "tmpdir"
require "fileutils"

class MakeGizmo
  attr_reader :id
  def initialize(id:) = (@id = id)
end
class GizmoMade < RubyEventStore::Event; end

# An async projection (#22) is NOT run in the append transaction; it's driven off
# the outbox by the worker — eventually consistent, append-only write latency.
RSpec.describe "async projection (#22)" do
  before do
    Shaolin::Registry.reset!
    Shaolin::Provider.reset!
    Shaolin::Kernel.reset!
    PgTest.reset_schema!
    $proj_seen = Queue.new
  end

  def boot(root)
    dir = File.join(root, "app/modules/gizmos")
    FileUtils.mkdir_p(File.join(dir, "command_handlers"))
    FileUtils.mkdir_p(File.join(dir, "projections"))
    File.write(File.join(dir, "module.rb"), 'Shaolin.module("gizmos") {}')
    File.write(File.join(dir, "gizmo.rb"), <<~RUBY)
      module Gizmos
        class Gizmo
          include Shaolin::CQRS::Aggregate
          def make = apply(GizmoMade.new(data: { id: id }))
          on(GizmoMade) { |_e| }
        end
      end
    RUBY
    File.write(File.join(dir, "command_handlers/make_gizmo_handler.rb"), <<~RUBY)
      module Gizmos
        module CommandHandlers
          class MakeGizmoHandler < Shaolin::CQRS::CommandHandler
            handles MakeGizmo
            def call(cmd) = aggregate_repository.unit_of_work(Gizmos::Gizmo.new(cmd.id)) { |w| w.make }
          end
        end
      end
    RUBY
    File.write(File.join(dir, "projections/gizmo_projection.rb"), <<~RUBY)
      module Gizmos
        module Projections
          class GizmoProjection < Shaolin::CQRS::Projection
            async
            on(GizmoMade) { |event| $proj_seen << event.data[:id] }
          end
        end
      end
    RUBY

    Shaolin::AR.register_provider!(config: PgTest::CONFIG)
    Shaolin::CQRS.register_provider!
    Shaolin::Jobs.register_provider!
    Shaolin::App.new(root: root).boot!
  end

  it "skips the append tx (async) and is run by the worker via the outbox" do
    Dir.mktmpdir do |root|
      app = boot(root)
      app["gizmos"]["cqrs.command_bus"].call(MakeGizmo.new(id: "w1"))

      expect($proj_seen).to be_empty # NOT run synchronously on append
      expect(Shaolin::Jobs::OutboxJob.where(status: "pending").count).to eq(1) # enqueued instead

      Shaolin::Jobs::Worker.new(event_store: Shaolin::Kernel["cqrs.event_store"]).run_once
      expect($proj_seen.pop).to eq("w1") # ran asynchronously, worker-driven
      expect(Shaolin::Jobs::OutboxJob.where(status: "done").count).to eq(1)
    end
  end
end

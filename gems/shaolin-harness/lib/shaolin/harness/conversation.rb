require_relative "runner"
require_relative "conversation/read_model"

module Shaolin
  # A long-lived, human-paced conversation — the CONVERSATIONAL mode of the
  # harness state machine (issue #2). Same engine as an autonomous `Harness`
  # (event-sourced run, gates, tools=commands, reasoning, durable/resume); the two
  # deltas are: a turn is fed an inbound human message, and the run rests at an
  # `await` gate between turns instead of running to a terminal. So one mental
  # model — a state machine over LLM steps — with two modes.
  #
  #   class Companion < Shaolin::Conversation
  #     llm model: "gpt-4.1"
  #     stages :onboarding, :free, :offer, :subscriber   # the funnel (strict)
  #     edges  onboarding: :free, free: :offer, offer: :subscriber
  #     window 12                                          # recent-message memory
  #     context { |run| "You are a warm companion. stage=#{run.stage}." }
  #
  #     gate :reply, entry: true do                        # responder (no prompt =>
  #       tools record_offer: RecordOffer                  #   uses context + history)
  #       on_result do |out, run|
  #         run.advance_to(:offer) if out.tool_used?(:record_offer)
  #         run.transition_to(:awaiting_user)              # rest until next message
  #       end
  #     end
  #     gate :awaiting_user, await: true                   # resting state
  #
  #     on_turn { |reply, run| } # deterministic always-do updates (optional)
  #   end
  #
  #   session = Companion.session(id:, llm:, repo:, command_bus:)
  #   session.receive("hi")   # => reply text; session.stage / .awaiting? / .history
  class Conversation < Harness
    WINDOW_DEFAULT = 12

    # --- conversational DSL (in addition to the gate DSL from Harness) ---
    module DSL
      def stages(*names)
        return @stages || [] if names.empty?

        @stages = names.map(&:to_s)
      end

      # edges(onboarding: :free, free: [:offer, :free]) — allowed funnel
      # transitions. Strict: `run.advance_to` rejects anything not declared.
      def edges(map = nil)
        return (@edges || {}) if map.nil?

        @edges = map.each_with_object({}) { |(from, tos), h| h[from.to_s] = Array(tos).map(&:to_s) }
      end

      def initial_stage(name = nil)
        @initial_stage = name.to_s if name
        @initial_stage ||= stages.first
      end

      def window(n = nil)
        @window = n if n
        @window || WINDOW_DEFAULT
      end

      def context(&block)
        @context = block if block
        @context
      end

      def on_turn(&block)
        @on_turn = block if block
        @on_turn
      end

      # Declarative per-turn tag stamping: tags { |run| { geo: ..., variant: ... } }.
      # Computed each turn and merged onto the session (projected to conversations_read
      # for cross-user funnel queries). Imperative stamping is `run.tag(...)` /
      # `session.tag(...)` from anywhere (e.g. entry-profile at the first turn).
      def tags(&block)
        @tags_block = block if block
        @tags_block
      end

      # Normalized funnel edges handed to the run at start (so the aggregate
      # validates transitions itself); nil when no stages are declared.
      def stage_edges = stages.empty? ? nil : edges

      # The message array for a conversational gate that declares no prompt:
      # the persona/system line (if any) + the recent-window history.
      def context_for(run)
        msgs = run.recent(window)
        ctx = context&.call(run)
        ctx ? [{ role: "system", content: ctx.to_s }] + msgs : msgs
      end
    end

    extend DSL

    def self.inherited(subclass)
      super
      subclass.extend(DSL)
    end

    # A bound handle for one session id: `receive(message)` starts the run on the
    # first message, then runs one human-paced turn and returns the reply.
    class Session
      def initialize(harness:, id:, llm:, repo:, command_bus: nil)
        @runner = Shaolin::Harness::Runner.new(harness: harness, llm: llm, repo: repo, command_bus: command_bus)
        @id = id
      end

      def receive(message)
        @runner.start(id: @id) unless @runner.started?(@id)
        @runner.receive(@id, input: message)
      end

      def run = @runner.load(@id)
      def stage = run.stage
      def awaiting? = @runner.awaiting?(run)
      def history = run.history
      def tags = run.tags

      # Stamp app dimensions onto the session (geo/device/variant/segment).
      def tag(**attrs)
        @runner.start(id: @id) unless @runner.started?(@id)
        @runner.tag(@id, attrs)
        self
      end
    end

    def self.session(id:, llm:, repo:, command_bus: nil)
      Session.new(harness: self, id: id, llm: llm, repo: repo, command_bus: command_bus)
    end

    # Opt-in: maintain the cross-user `conversations_read` projection + register the
    # `conversations.read` query facade in the Kernel. Register AFTER :cqrs.
    def self.register_read_model!
      Shaolin.register_provider(:conversation_read) do
        start do
          Schema.create!
          es = Shaolin::Kernel["cqrs.event_store"]
          es.subscribe(Projector.new, to: [Events::RunStarted, Events::StageChanged,
                                           Events::MessageReceived, Events::Tagged])
          Shaolin::Kernel.register("conversations.read", Reader)
        end
      end
    end
  end
end

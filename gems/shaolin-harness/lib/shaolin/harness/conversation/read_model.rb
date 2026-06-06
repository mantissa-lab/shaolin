require "active_record"

module Shaolin
  class Conversation < Harness
    # Cross-user queryable read-side for conversations (issue #5). A sync projection
    # over the conversation events maintains one row per session — stage, turn
    # count, last activity, and app-stamped `tags` (geo/variant/segment/…) — so
    # other modules (analytics, an offer engine, entitlement) can query the whole
    # user base ("everyone in stage=offer", ">N turns today", "tags->>'geo'='DE'")
    # WITHOUT driving the session. CQRS: the run stream is the write side; this is
    # the read model. Opt-in via `Shaolin::Conversation.register_read_model!`.
    module Schema
      SCHEMA_LOCK_KEY = 7_283_012

      def self.create!
        ::ActiveRecord::Base.connection_pool.with_connection do |conn|
          conn.execute("SELECT pg_advisory_lock(#{SCHEMA_LOCK_KEY})")
          begin
            create_table(conn)
          ensure
            conn.execute("SELECT pg_advisory_unlock(#{SCHEMA_LOCK_KEY})")
          end
        end
      end

      def self.create_table(conn)
        unless conn.table_exists?("conversations_read")
          conn.create_table(:conversations_read, id: false) do |t|
            t.string   :session_id,   null: false
            t.string   :harness
            t.string   :stage
            t.integer  :turn_count,   null: false, default: 0
            t.datetime :last_turn_at
            t.jsonb    :tags,         null: false, default: {}
            t.timestamps
          end
          conn.add_index(:conversations_read, :session_id, unique: true)
        end
        conn.add_index(:conversations_read, :stage) unless conn.index_exists?(:conversations_read, :stage)
      end
    end

    # One projected row per session. Query via the scopes (or Reader).
    class ReadRow < ::ActiveRecord::Base
      self.table_name = "conversations_read"
      self.primary_key = "session_id"

      def self.in_stage(stage) = where(stage: stage.to_s)

      # turn_count >= n, optionally only sessions active since a cutoff (e.g. today).
      def self.with_min_turns(n, since: nil)
        rel = where("turn_count >= ?", n)
        since ? rel.where("last_turn_at >= ?", since) : rel
      end

      # AND-filter by jsonb tags: with_tags(geo: "DE", variant: "tripwire").
      def self.with_tags(attrs)
        attrs.reduce(all) { |rel, (k, v)| rel.where("tags ->> ? = ?", k.to_s, v.to_s) }
      end
    end

    # Sync subscriber: keeps a session's row in step with its events, inside the
    # append transaction (so the read model is consistent with the write side).
    class Projector
      def call(event)
        sid = event.data[:run_id]
        return unless sid

        case event
        when Harness::Events::RunStarted
          upsert(sid) { |r| r.harness = event.data[:harness]; r.stage = event.data[:stage]&.to_s }
        when Harness::Events::StageChanged
          upsert(sid) { |r| r.stage = event.data[:to] }
        when Harness::Events::MessageReceived
          upsert(sid) { |r| r.turn_count += 1; r.last_turn_at = event.metadata[:timestamp] || r.last_turn_at }
        when Harness::Events::Tagged
          upsert(sid) { |r| r.tags = (r.tags || {}).merge(event.data[:tags].transform_keys(&:to_s)) }
        end
      end

      private

      def upsert(session_id)
        row = ReadRow.find_or_initialize_by(session_id: session_id)
        yield row
        row.save!
      end
    end

    # Query facade registered as `conversations.read` — read by any module without
    # driving the session (framework infra, not a cross-module reach-in).
    module Reader
      module_function

      def find(session_id) = ReadRow.find_by(session_id: session_id.to_s)
      def in_stage(stage) = ReadRow.in_stage(stage)
      def with_min_turns(n, since: nil) = ReadRow.with_min_turns(n, since: since)
      def all = ReadRow.all

      # Compose everything: query(stage: "offer", min_turns: 3, since: today, tags: {geo: "DE"}).
      def query(stage: nil, min_turns: nil, since: nil, tags: {})
        rel = ReadRow.all
        rel = rel.in_stage(stage) if stage
        rel = rel.with_min_turns(min_turns, since: since) if min_turns
        rel = rel.with_tags(tags) if tags && !tags.empty?
        rel
      end
    end
  end
end

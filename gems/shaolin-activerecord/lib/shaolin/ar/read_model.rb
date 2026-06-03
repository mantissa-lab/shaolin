require "active_record"

module Shaolin
  module AR
    # Base for projection read models. `project` is an idempotent upsert keyed by
    # the aggregate id, so replaying an event stream to rebuild a read model is
    # deterministic (projections should set absolute state, not increment).
    class ReadModel < ::ActiveRecord::Base
      self.abstract_class = true

      def self.project(id:)
        record = find_or_initialize_by(primary_key => id)
        yield record
        record.save!
        record
      end
    end
  end
end

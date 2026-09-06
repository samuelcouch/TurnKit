# frozen_string_literal: true

gem "activejob", ">= 7.2"
gem "activerecord", ">= 7.2"
require "active_job"
require "active_record"

module TurnKit
  class Job < ActiveJob::Base
    def perform(turn_id = nil)
      Background.perform(turn_id)
    end
  end

  # Schedule with the application's existing recurring-job facility.
  class ReconcileJob < ActiveJob::Base
    def perform
      Background.reconcile
    end
  end
end

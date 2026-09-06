# frozen_string_literal: true

ENV["RAILS_ENV"] = "development"
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "solid_queue"
require "turnkit"
require "turnkit/job"

module DurableResearch
  class Application < Rails::Application
    config.root = __dir__
    config.load_defaults 7.2
    config.eager_load = false
    config.active_job.queue_adapter = :solid_queue
    config.logger = ActiveSupport::Logger.new($stderr)
    config.log_level = :warn
    config.secret_key_base = "local-headless-example-not-a-web-application"
  end
end
Rails.application.initialize!

# No associations are needed by ActiveRecordStore; these are persistence rows,
# not TurnKit's conversation/turn domain objects.
module Turnkit
  class Conversation < ActiveRecord::Base; self.table_name = "turnkit_conversations"; end
  class Turn < ActiveRecord::Base; self.table_name = "turnkit_turns"; end
  class Message < ActiveRecord::Base; self.table_name = "turnkit_messages"; end
  class ToolExecution < ActiveRecord::Base; self.table_name = "turnkit_tool_executions"; end
  class Delivery < ActiveRecord::Base; self.table_name = "turnkit_deliveries"; end
  class Wait < ActiveRecord::Base; self.table_name = "turnkit_waits"; end
end

module DurableResearch
  class Report < ActiveRecord::Base; self.table_name = "demo_reports"; end
  class Signal < ActiveRecord::Base; self.table_name = "demo_signals"; end
  LIVE = ENV["TURNKIT_DEMO_LIVE"] == "1"
end

require_relative "agents"

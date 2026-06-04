# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module TurnKit
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("install/templates", __dir__)

      class_option :table_prefix, type: :string, default: "turnkit", desc: "Database table prefix."

      def copy_initializer
        template "initializer.rb", "config/initializers/turnkit.rb"
      end

      def copy_models
        template "conversation.rb", "app/models/turnkit/conversation.rb"
        template "turn.rb", "app/models/turnkit/turn.rb"
        template "message.rb", "app/models/turnkit/message.rb"
        template "tool_execution.rb", "app/models/turnkit/tool_execution.rb"
      end

      def copy_migration
        migration_template "create_turnkit_tables.rb", "db/migrate/create_turnkit_tables.rb"
      end

      def self.next_migration_number(dirname)
        if ActiveRecord::Base.timestamped_migrations
          Time.now.utc.strftime("%Y%m%d%H%M%S")
        else
          "%.3d" % (current_migration_number(dirname) + 1)
        end
      end

      private
        def table_prefix
          options[:table_prefix]
        end
    end
  end
end

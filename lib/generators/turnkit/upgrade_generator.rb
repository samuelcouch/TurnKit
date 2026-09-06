# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module TurnKit
  module Generators
    class UpgradeGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      namespace "turnkit:upgrade"
      source_root File.expand_path("upgrade/templates", __dir__)
      source_paths << File.expand_path("install/templates", __dir__)

      class_option :table_prefix, type: :string, default: "turnkit", desc: "Database table prefix."

      def copy_models
        template "delivery.rb", "app/models/turnkit/delivery.rb"
        template "wait.rb", "app/models/turnkit/wait.rb"
      end

      def copy_migration
        migration_template "add_turnkit_durable_orchestration.rb", "db/migrate/add_turnkit_durable_orchestration.rb"
      end

      def self.next_migration_number(dirname)
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      private
        def table_prefix = options[:table_prefix]
    end
  end
end

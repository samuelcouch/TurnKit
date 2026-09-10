# frozen_string_literal: true

require_relative "app"
require "erb"

ActiveRecord::Migration.verbose = false
connection = ActiveRecord::Base.connection
connection.transaction do
  unless connection.table_exists?(:iv_conversations)
    table_prefix = "iv"
    template = File.expand_path("../../lib/generators/turnkit/install/templates/create_turnkit_tables.rb", __dir__)
    Object.class_eval(ERB.new(File.read(template)).result(binding), template)
    CreateTurnkitTables.migrate(:up)
  end
  unless connection.table_exists?(:iv_barriers)
    connection.create_table(:iv_barriers) do |t|
      t.string :turn_uid, :name, null: false
      t.boolean :entered, :released, :crash, :crashed, default: false, null: false
      t.integer :pid
      t.index [:turn_uid, :name], unique: true
    end
    connection.create_table(:iv_evidence) do |t|
      t.string :turn_uid, :kind, null: false
      t.jsonb :data, null: false
      t.timestamps
    end
  end
end
puts "Ready: Rails #{Rails.version}, ActiveRecord #{ActiveRecord.version}, ActiveJob #{ActiveJob.version}, Sidekiq #{Sidekiq::VERSION}, Ruby #{RUBY_VERSION}"

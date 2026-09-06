# frozen_string_literal: true

require_relative "app"
require "erb"

configuration = ActiveRecord::Base.connection_db_config
unless configuration.database.match?(/\Aturnkit_demo(?:_\w+)?\z/)
  abort "Use a dedicated database named turnkit_demo or turnkit_demo_<suffix>."
end
begin
  ActiveRecord::Base.connection.execute("SELECT 1")
rescue ActiveRecord::NoDatabaseError
  ActiveRecord::Tasks::DatabaseTasks.create(configuration)
  ActiveRecord::Base.establish_connection(configuration)
end

# Reuse the actual install templates rather than maintaining a second schema.
# Run once per dedicated database, atomically; never reset existing tables.
connection = ActiveRecord::Base.connection
connection.transaction do
  unless connection.table_exists?(:solid_queue_jobs)
    load File.join(Gem::Specification.find_by_name("solid_queue").full_gem_path,
      "lib/generators/solid_queue/install/templates/db/queue_schema.rb")
  end
  unless connection.table_exists?(:turnkit_conversations)
    table_prefix = "turnkit"
    template = File.expand_path("../../lib/generators/turnkit/install/templates/create_turnkit_tables.rb", __dir__)
    Object.class_eval(ERB.new(File.read(template)).result(binding), template)
    CreateTurnkitTables.migrate(:up)
  end
  unless connection.table_exists?(:demo_reports)
    connection.create_table(:demo_reports) do |t|
      t.string :turn_uid, null: false
      t.text :body, null: false
      t.json :sources, null: false
      t.timestamps
    end
  end
  unless connection.table_exists?(:demo_signals)
    connection.create_table(:demo_signals) do |t|
      t.string :turn_uid, null: false
      t.string :name, null: false
      t.integer :pid, null: false
      t.boolean :released, default: false, null: false
      t.timestamps
      t.index [:turn_uid, :name], unique: true
    end
  end
end
puts "Durable research database ready: #{configuration.database}"

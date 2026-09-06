# frozen_string_literal: true

class CreateTurnkitTables < ActiveRecord::Migration[7.1]
  def change
    create_table :<%= table_prefix %>_conversations do |t|
      t.string :uid, null: false
      t.string :agent_name, null: false
      t.string :model
      t.string :subject_type
      t.string :subject_id
      t.json :metadata, null: false, default: {}
      t.timestamps

      t.index :uid, unique: true
      t.index [ :subject_type, :subject_id ]
    end

    create_table :<%= table_prefix %>_turns do |t|
      t.string :uid, null: false
      t.string :conversation_uid, null: false
      t.string :agent_name, null: false
      t.string :parent_turn_uid
      t.string :parent_tool_execution_uid
      t.string :root_turn_uid, null: false
      t.integer :context_message_sequence, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.string :model
      t.json :options, null: false, default: {}
      t.json :usage, null: false, default: {}
      t.decimal :cost, precision: 14, scale: 6
      t.json :error
      t.text :output_text
      t.json :output_data
      t.datetime :submitted_at
      t.string :claim_token
      t.datetime :started_at
      t.datetime :heartbeat_at
      t.datetime :completed_at
      t.timestamps

      t.index :uid, unique: true
      t.index :conversation_uid
      t.index :root_turn_uid
      t.index [ :status, :heartbeat_at ]
      t.index [ :status, :submitted_at, :updated_at ], name: "index_<%= table_prefix %>_turns_on_maintenance"
    end

    create_table :<%= table_prefix %>_deliveries do |t|
      t.string :uid, null: false
      t.string :source_conversation_uid, null: false
      t.string :destination_conversation_uid, null: false
      t.string :source_turn_uid
      t.string :key, null: false
      t.json :payload, null: false, default: {}
      t.string :message_uid
      t.datetime :delivered_at
      t.timestamps

      t.index :uid, unique: true
      t.index :key, unique: true
      t.index [ :source_conversation_uid, :created_at ]
      t.index [ :destination_conversation_uid, :delivered_at ]
      t.index [ :delivered_at, :created_at ], name: "index_<%= table_prefix %>_deliveries_on_pending"
    end

    create_table :<%= table_prefix %>_waits do |t|
      t.string :turn_uid, null: false
      t.string :target_turn_uid, null: false
      t.timestamps

      t.index [ :turn_uid, :target_turn_uid ], unique: true
      t.index :target_turn_uid
    end

    create_table :<%= table_prefix %>_messages do |t|
      t.string :uid, null: false
      t.string :conversation_uid, null: false
      t.string :turn_uid
      t.string :role, null: false
      t.string :kind, null: false
      t.integer :sequence, null: false
      t.json :content, null: false, default: []
      t.string :tool_execution_uid
      t.string :provider_message_id
      t.json :metadata, null: false, default: {}
      t.timestamps

      t.index :uid, unique: true
      t.index [ :conversation_uid, :sequence ], unique: true
      t.index [ :conversation_uid, :turn_uid ]
      t.index :turn_uid
    end

    create_table :<%= table_prefix %>_tool_executions do |t|
      t.string :uid, null: false
      t.string :turn_uid, null: false
      t.string :tool_call_id, null: false
      t.string :tool_name, null: false
      t.string :status, null: false, default: "pending"
      t.json :arguments, null: false, default: {}
      t.json :result
      t.json :error
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps

      t.index :uid, unique: true
      t.index [ :turn_uid, :tool_call_id ], unique: true
      t.index [ :turn_uid, :status ]
    end
  end
end

# frozen_string_literal: true

class AddTurnkitDurableOrchestration < ActiveRecord::Migration[7.1]
  def change
    add_column :<%= table_prefix %>_turns, :submitted_at, :datetime
    add_column :<%= table_prefix %>_turns, :claim_token, :string
    add_index :<%= table_prefix %>_turns, [ :status, :submitted_at, :updated_at ], name: "index_<%= table_prefix %>_turns_on_maintenance"

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
  end
end

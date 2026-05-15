class CreateRuntimeInstances < ActiveRecord::Migration[8.1]
  def change
    create_table :runtime_instances do |t|
      t.references :app, null: false, foreign_key: true
      t.references :node, null: false, foreign_key: true
      t.string :container_id
      t.string :status, null: false, default: "starting"
      t.datetime :started_at
      t.datetime :last_seen_at
      t.datetime :stopped_at
      t.integer :exit_code
      t.string :failure_message

      t.timestamps
    end

    add_index :runtime_instances, :container_id, unique: true
    add_index :runtime_instances, :status
  end
end

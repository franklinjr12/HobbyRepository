class CreateColdStartMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :cold_start_metrics do |t|
      t.references :app, null: false, foreign_key: true
      t.references :runtime_instance, null: false, foreign_key: true
      t.datetime :started_at, null: false
      t.datetime :finished_at, null: false
      t.string :status, null: false
      t.integer :container_start_duration_ms
      t.integer :health_check_duration_ms
      t.integer :total_wake_duration_ms, null: false
      t.text :failure_message

      t.timestamps
    end

    add_index :cold_start_metrics, %i[app_id started_at]
    add_index :cold_start_metrics, %i[app_id status]
    add_index :cold_start_metrics, :status
  end
end

class CreateAppRequestMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :app_request_metrics do |t|
      t.references :app, null: false, foreign_key: true
      t.datetime :occurred_at, null: false
      t.integer :status_code
      t.boolean :cold_start, default: false, null: false
      t.integer :wake_duration_ms
      t.string :request_method
      t.string :path

      t.timestamps
    end

    add_index :app_request_metrics, %i[app_id occurred_at]
    add_index :app_request_metrics, %i[app_id cold_start]
    add_index :app_request_metrics, :status_code
  end
end

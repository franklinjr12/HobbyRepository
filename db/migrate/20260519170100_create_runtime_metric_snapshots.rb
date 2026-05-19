class CreateRuntimeMetricSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :runtime_metric_snapshots do |t|
      t.references :app, null: false, foreign_key: true
      t.references :runtime_instance, null: false, foreign_key: true
      t.datetime :captured_at, null: false
      t.bigint :memory_usage_bytes
      t.decimal :cpu_usage_percent, precision: 8, scale: 3
      t.integer :uptime_seconds

      t.timestamps
    end

    add_index :runtime_metric_snapshots, %i[app_id captured_at]
    add_index :runtime_metric_snapshots, %i[runtime_instance_id captured_at],
              name: "index_runtime_metrics_on_runtime_and_captured_at"
  end
end

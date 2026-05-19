class CreateAppLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :app_logs do |t|
      t.references :app, null: false, foreign_key: true
      t.references :runtime_instance, foreign_key: true
      t.references :deployment, foreign_key: true
      t.string :stream, null: false
      t.datetime :logged_at, null: false
      t.text :message, null: false
      t.string :content_hash, null: false

      t.timestamps
    end

    add_index :app_logs, %i[app_id logged_at]
    add_index :app_logs, %i[runtime_instance_id stream logged_at content_hash],
              unique: true,
              name: "index_app_logs_on_runtime_stream_time_hash"
    add_index :app_logs, :stream
  end
end

class CreateAppEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :app_events do |t|
      t.references :app, null: false, foreign_key: true
      t.string :event_type, null: false
      t.string :message, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :app_events, :event_type
    add_index :app_events, :created_at
  end
end

class AddSleepActivityTrackingToApps < ActiveRecord::Migration[8.1]
  def change
    change_table :apps, bulk: true do |t|
      t.datetime :last_request_at
      t.integer :active_request_count, default: 0, null: false
      t.integer :active_connection_count, default: 0, null: false
      t.datetime :drain_started_at
    end

    add_index :apps, :last_request_at
    add_index :apps, :drain_started_at
  end
end

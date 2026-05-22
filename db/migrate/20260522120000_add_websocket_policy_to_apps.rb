class AddWebsocketPolicyToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :max_connection_duration_seconds, :integer, default: 3600, null: false
  end
end

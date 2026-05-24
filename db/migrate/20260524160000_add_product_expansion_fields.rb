class AddProductExpansionFields < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :sleep_mode, :string, null: false, default: "deep_sleep"
    add_index :apps, :sleep_mode

    change_table :routes, bulk: true do |t|
      t.string :ownership_status, null: false, default: "pending"
      t.string :ownership_token
      t.datetime :ownership_verified_at
      t.datetime :tls_provisioned_at
    end
    add_index :routes, :ownership_status
    add_index :routes, :ownership_token, unique: true

    change_table :deployments, bulk: true do |t|
      t.string :source_type, null: false, default: "image"
      t.string :git_repository_url
      t.string :git_ref
      t.string :build_status
      t.text :build_logs
    end
    add_index :deployments, :source_type
    add_index :deployments, :build_status
  end
end

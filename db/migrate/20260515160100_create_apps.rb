class CreateApps < ActiveRecord::Migration[8.1]
  def change
    create_table :apps do |t|
      t.references :node, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.string :status, null: false, default: "created"
      t.string :image_reference
      t.integer :internal_port
      t.string :health_check_path, null: false, default: "/"
      t.integer :idle_timeout_seconds, null: false, default: 900
      t.integer :startup_timeout_seconds, null: false, default: 60
      t.bigint :memory_limit_bytes
      t.decimal :cpu_limit, precision: 6, scale: 2
      t.datetime :last_activity_at

      t.timestamps
    end

    add_index :apps, :slug, unique: true
    add_index :apps, :status
  end
end

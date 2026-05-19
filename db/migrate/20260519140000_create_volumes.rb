class CreateVolumes < ActiveRecord::Migration[8.1]
  def change
    create_table :volumes do |t|
      t.references :app, null: false, foreign_key: true, index: { unique: true }
      t.string :mount_path, null: false
      t.string :host_path, null: false
      t.bigint :size_limit_bytes
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :volumes, :host_path, unique: true
    add_index :volumes, :status
  end
end

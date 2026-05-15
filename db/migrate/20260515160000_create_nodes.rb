class CreateNodes < ActiveRecord::Migration[8.1]
  def change
    create_table :nodes do |t|
      t.string :name, null: false
      t.string :hostname, null: false
      t.string :status, null: false, default: "active"
      t.datetime :last_heartbeat_at
      t.decimal :capacity_cpu, precision: 8, scale: 2
      t.bigint :capacity_memory_bytes
      t.boolean :local, null: false, default: false

      t.timestamps
    end

    add_index :nodes, :hostname, unique: true
    add_index :nodes, :local, unique: true, where: "local"
    add_index :nodes, :status
  end
end

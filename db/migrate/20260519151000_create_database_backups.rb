class CreateDatabaseBackups < ActiveRecord::Migration[8.1]
  def change
    create_table :database_backups do |t|
      t.references :database_resource, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :filename, null: false
      t.text :encrypted_content
      t.text :failure_message
      t.datetime :completed_at

      t.timestamps
    end

    add_index :database_backups, :status
  end
end

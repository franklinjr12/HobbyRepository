class CreateDatabaseResources < ActiveRecord::Migration[8.1]
  def change
    create_table :database_resources do |t|
      t.references :app, null: false, foreign_key: true, index: { unique: true }
      t.string :database_type, null: false, default: "postgres"
      t.string :database_name, null: false
      t.string :username, null: false
      t.text :encrypted_password, null: false
      t.string :status, null: false, default: "pending"
      t.string :database_url_env_var, null: false, default: "DATABASE_URL"
      t.string :database_name_env_var, null: false, default: "DATABASE_NAME"
      t.string :username_env_var, null: false, default: "DATABASE_USERNAME"
      t.string :password_env_var, null: false, default: "DATABASE_PASSWORD"
      t.string :host_env_var, null: false, default: "DATABASE_HOST"
      t.string :port_env_var, null: false, default: "DATABASE_PORT"
      t.string :host, null: false, default: "localhost"
      t.integer :port, null: false, default: 5432
      t.datetime :provisioned_at
      t.datetime :credentials_rotated_at
      t.text :failure_message

      t.timestamps
    end

    add_index :database_resources, :database_name, unique: true
    add_index :database_resources, :username, unique: true
    add_index :database_resources, :status
  end
end

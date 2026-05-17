class CreateRoutes < ActiveRecord::Migration[8.1]
  def change
    create_table :routes do |t|
      t.references :app, null: false, foreign_key: true
      t.string :hostname, null: false
      t.string :route_type, null: false, default: "generated_subdomain"
      t.boolean :active, null: false, default: true
      t.string :tls_status, null: false, default: "not_configured"

      t.timestamps
    end

    add_index :routes, :hostname, unique: true
    add_index :routes, :route_type
    add_index :routes, :active
  end
end

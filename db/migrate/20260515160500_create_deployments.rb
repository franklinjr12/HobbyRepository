class CreateDeployments < ActiveRecord::Migration[8.1]
  def change
    create_table :deployments do |t|
      t.references :app, null: false, foreign_key: true
      t.string :image_reference, null: false
      t.jsonb :env_snapshot, null: false, default: {}
      t.integer :port, null: false
      t.string :health_check_path, null: false, default: "/"
      t.string :status, null: false, default: "created"
      t.boolean :current, null: false, default: false
      t.datetime :deployed_at

      t.timestamps
    end

    add_index :deployments, :status
    add_index :deployments, %i[app_id current],
              unique: true,
              where: "current",
              name: "index_deployments_on_current_app"
  end
end

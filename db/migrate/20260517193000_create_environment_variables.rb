class CreateEnvironmentVariables < ActiveRecord::Migration[8.1]
  def change
    create_table :environment_variables do |t|
      t.references :app, null: false, foreign_key: true
      t.string :key, null: false
      t.text :value, null: false
      t.boolean :secret, null: false, default: false

      t.timestamps
    end

    add_index :environment_variables, [ :app_id, :key ], unique: true
  end
end

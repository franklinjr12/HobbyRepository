class CreateTeams < ActiveRecord::Migration[8.1]
  def change
    create_table :teams do |t|
      t.string :name, null: false
      t.string :slug, null: false

      t.timestamps
    end

    add_index :teams, :slug, unique: true
    add_reference :apps, :team, foreign_key: true
  end
end

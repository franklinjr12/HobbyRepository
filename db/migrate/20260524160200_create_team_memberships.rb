class CreateTeamMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :team_memberships do |t|
      t.references :team, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: "viewer"

      t.timestamps
    end

    add_index :team_memberships, %i[team_id user_id], unique: true
    add_index :team_memberships, :role
  end
end

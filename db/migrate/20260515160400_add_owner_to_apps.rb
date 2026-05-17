class AddOwnerToApps < ActiveRecord::Migration[8.1]
  def change
    add_reference :apps, :owner, foreign_key: { to_table: :users }, index: true
  end
end

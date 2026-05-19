class AddReadinessChecks < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :health_check_kind, :string, null: false, default: "http"
    add_column :deployments, :health_check_kind, :string, null: false, default: "http"

    change_column_null :apps, :health_check_path, true
    change_column_null :deployments, :health_check_path, true

    change_table :runtime_instances, bulk: true do |t|
      t.string :health_check_result
      t.integer :health_check_status_code
      t.datetime :health_check_checked_at
    end
  end
end

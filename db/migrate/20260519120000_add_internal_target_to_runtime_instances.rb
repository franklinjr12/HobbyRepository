class AddInternalTargetToRuntimeInstances < ActiveRecord::Migration[8.1]
  def change
    change_table :runtime_instances, bulk: true do |t|
      t.string :internal_host
      t.integer :internal_port
    end
  end
end

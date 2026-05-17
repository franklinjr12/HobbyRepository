class AddDeploymentToRuntimeInstances < ActiveRecord::Migration[8.1]
  def change
    add_reference :runtime_instances, :deployment, foreign_key: true
  end
end

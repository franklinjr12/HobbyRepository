require "test_helper"

class DeploymentTest < ActiveSupport::TestCase
  setup do
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @owner = User.create!(email: "deployments@example.com", password: "password123")
    @app = App.create!(
      name: "Deployable",
      slug: "deployable",
      owner: @owner,
      node: @node,
      image_reference: "example/app:latest",
      internal_port: 3000
    )
  end

  test "copies app runtime configuration by default" do
    deployment = @app.deployments.create!

    assert_equal "example/app:latest", deployment.image_reference
    assert_equal 3000, deployment.port
    assert_equal "/", deployment.health_check_path
  end

  test "mark current replaces existing current deployment" do
    old_deployment = @app.deployments.create!(image_reference: "example/app:old", port: 3000, current: true)
    new_deployment = @app.deployments.create!(image_reference: "example/app:new", port: 3000)

    new_deployment.mark_current!

    assert new_deployment.reload.current?
    assert_not old_deployment.reload.current?
    assert_not_nil new_deployment.deployed_at
  end

  test "records creation event" do
    deployment = @app.deployments.create!(image_reference: "example/app:event", port: 3000)

    event = @app.app_events.find_by!(event_type: "deployment.created")
    assert_equal deployment.id, event.metadata["deployment_id"]
  end
end

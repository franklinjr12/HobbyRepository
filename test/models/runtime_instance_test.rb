require "test_helper"

class RuntimeInstanceTest < ActiveSupport::TestCase
  test "inherits node placement from app" do
    node = Node.create!(name: "Local", hostname: "local.test", local: true)
    owner = User.create!(email: "runtime@example.com", password: "password123")
    app = App.create!(name: "Placed", slug: "placed", owner: owner, node: node)

    runtime_instance = RuntimeInstance.create!(app: app, status: "starting")

    assert_equal node, runtime_instance.node
  end

  test "inherits current deployment from app" do
    node = Node.create!(name: "Local", hostname: "local.test", local: true)
    owner = User.create!(email: "runtime-deployment@example.com", password: "password123")
    app = App.create!(name: "Runtime Deployment", slug: "runtime-deployment", owner: owner, node: node)
    deployment = app.deployments.create!(image_reference: "example/app:latest", port: 3000, current: true)

    runtime_instance = RuntimeInstance.create!(app: app, status: "starting")

    assert_equal deployment, runtime_instance.deployment
  end
end

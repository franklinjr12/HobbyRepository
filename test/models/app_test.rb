require "test_helper"

class AppTest < ActiveSupport::TestCase
  setup do
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @owner = User.create!(email: "owner@example.com", password: "password123")
  end

  test "assigns defaults and local node for new app" do
    app = App.create!(name: "Tiny Site", slug: "Tiny Site", owner: @owner)

    assert_equal @node, app.node
    assert_equal @owner, app.owner
    assert_equal "tiny-site", app.slug
    assert_equal "created", app.status
    assert_equal 900, app.idle_timeout_seconds
    assert_equal 60, app.startup_timeout_seconds
    assert_equal "/", app.health_check_path
    assert_equal "tiny-site.localhost", app.default_route.hostname
    assert_equal [ "app.created" ], app.app_events.pluck(:event_type)
  end

  test "requires an owner" do
    app = App.new(name: "Ownerless", slug: "ownerless", node: @node)

    assert_not app.valid?
    assert_includes app.errors[:owner], "must exist"
  end

  test "returns current deployment" do
    app = App.create!(name: "Deployable", slug: "deployable", owner: @owner, node: @node)
    old_deployment = app.deployments.create!(image_reference: "example/old:1", port: 3000)
    current_deployment = app.deployments.create!(
      image_reference: "example/new:2",
      port: 3000,
      current: true
    )

    assert_equal current_deployment, app.current_deployment
    assert_not old_deployment.current?
  end

  test "allows valid lifecycle transitions" do
    app = App.create!(name: "Wakeable", slug: "wakeable", owner: @owner, node: @node, status: "sleeping")

    assert app.may_transition_to?("waking")

    app.transition_to!("waking")
    app.transition_to!("running")

    assert_equal "running", app.status
  end

  test "rejects inconsistent lifecycle jumps" do
    app = App.create!(name: "Jumping", slug: "jumping", owner: @owner, node: @node, status: "sleeping")

    assert_not app.update(status: "running")
    assert_includes app.errors[:status], "cannot transition from sleeping to running"
  end

  test "manual override can repair app state with a reason" do
    app = App.create!(name: "Repairable", slug: "repairable", owner: @owner, node: @node, status: "sleeping")

    app.manual_override_to!("running", reason: "operator verified runtime")

    assert_equal "running", app.status
  end

  test "restore after restart conservatively clears active states" do
    app = App.create!(name: "Restarted", slug: "restarted", owner: @owner, node: @node, status: "sleeping")
    app.transition_to!("waking")
    app.transition_to!("running")

    app.restore_status_after_platform_restart!

    assert_equal "sleeping", app.status
  end
end

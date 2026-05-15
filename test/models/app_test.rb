require "test_helper"

class AppTest < ActiveSupport::TestCase
  setup do
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
  end

  test "assigns defaults and local node for new app" do
    app = App.create!(name: "Tiny Site", slug: "Tiny Site")

    assert_equal @node, app.node
    assert_equal "tiny-site", app.slug
    assert_equal "created", app.status
    assert_equal 900, app.idle_timeout_seconds
    assert_equal 60, app.startup_timeout_seconds
    assert_equal "/", app.health_check_path
  end

  test "allows valid lifecycle transitions" do
    app = App.create!(name: "Wakeable", slug: "wakeable", node: @node, status: "sleeping")

    assert app.may_transition_to?("waking")

    app.transition_to!("waking")
    app.transition_to!("running")

    assert_equal "running", app.status
  end

  test "rejects inconsistent lifecycle jumps" do
    app = App.create!(name: "Jumping", slug: "jumping", node: @node, status: "sleeping")

    assert_not app.update(status: "running")
    assert_includes app.errors[:status], "cannot transition from sleeping to running"
  end

  test "manual override can repair app state with a reason" do
    app = App.create!(name: "Repairable", slug: "repairable", node: @node, status: "sleeping")

    app.manual_override_to!("running", reason: "operator verified runtime")

    assert_equal "running", app.status
  end

  test "restore after restart conservatively clears active states" do
    app = App.create!(name: "Restarted", slug: "restarted", node: @node, status: "sleeping")
    app.transition_to!("waking")
    app.transition_to!("running")

    app.restore_status_after_platform_restart!

    assert_equal "sleeping", app.status
  end
end

require "test_helper"

class AppSchedulerTest < ActiveSupport::TestCase
  setup do
    @local_node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @remote_node = Node.create!(name: "Remote", hostname: "remote.test")
    @owner = User.create!(email: "scheduler@example.com", password: "password123")
    @app = App.create!(name: "Placed App", owner: @owner, node: @remote_node, status: "sleeping")
  end

  test "places apps on the local node for the MVP and records the decision" do
    placement = AppScheduler.new.place(@app, reason: "test_start")

    assert_equal @local_node, placement.node
    assert_equal @local_node, @app.reload.node
    event = @app.app_events.order(:created_at).last
    assert_equal "scheduler.placement_selected", event.event_type
    assert_equal @remote_node.id, event.metadata.fetch("previous_node_id")
    assert_equal @local_node.id, event.metadata.fetch("node_id")
  end
end

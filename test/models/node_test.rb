require "test_helper"

class NodeTest < ActiveSupport::TestCase
  test "ensure local node is idempotent" do
    first = Node.ensure_local!
    second = Node.ensure_local!

    assert_equal first, second
    assert first.local?
    assert_equal "active", first.status
  end

  test "only one local node is valid" do
    Node.create!(name: "Local", hostname: "local.test", local: true)
    other = Node.new(name: "Other", hostname: "other.test", local: true)

    assert_not other.valid?
    assert_includes other.errors[:local], "has already been taken"
  end

  test "heartbeat updates liveness and capacity" do
    node = Node.create!(name: "Worker", hostname: "worker.test", status: "degraded")

    node.heartbeat!(status: "active", capacity_cpu: 2.0, capacity_memory_bytes: 512.megabytes)

    assert_equal "active", node.status
    assert_equal BigDecimal("2.0"), node.capacity_cpu
    assert_equal 512.megabytes, node.capacity_memory_bytes
    assert node.last_heartbeat_at.present?
  end

  test "stale heartbeat nodes can be marked unhealthy" do
    stale = Node.create!(
      name: "Stale",
      hostname: "stale.test",
      status: "active",
      last_heartbeat_at: 10.minutes.ago
    )
    missing = Node.create!(
      name: "Missing",
      hostname: "missing.test",
      status: "active",
      last_heartbeat_at: nil
    )
    retired = Node.create!(
      name: "Retired",
      hostname: "retired.test",
      status: "retired",
      last_heartbeat_at: 10.minutes.ago
    )

    Node.mark_stale_unhealthy!(timeout: 1.minute)

    assert_equal "unhealthy", stale.reload.status
    assert_equal "unhealthy", missing.reload.status
    assert_equal "retired", retired.reload.status
  end
end

require "test_helper"

module Internal
  class NodeHeartbeatsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @previous_internal_token = ENV["PLATFORM_INTERNAL_TOKEN"]
      @previous_node_token = ENV["NODE_AGENT_SHARED_SECRET"]
      ENV["PLATFORM_INTERNAL_TOKEN"] = nil
      ENV["NODE_AGENT_SHARED_SECRET"] = nil
    end

    teardown do
      ENV["PLATFORM_INTERNAL_TOKEN"] = @previous_internal_token
      ENV["NODE_AGENT_SHARED_SECRET"] = @previous_node_token
    end

    test "records heartbeat and capacity for a reporting node" do
      post "/internal/nodes/heartbeat", params: {
        name: "Worker One",
        hostname: "worker-1.internal",
        status: "active",
        capacity_cpu: "2.5",
        capacity_memory_bytes: "1073741824"
      }

      assert_response :success
      node = Node.find_by!(hostname: "worker-1.internal")
      assert_equal "Worker One", node.name
      assert_equal "active", node.status
      assert_equal BigDecimal("2.5"), node.capacity_cpu
      assert_equal 1_073_741_824, node.capacity_memory_bytes
      assert node.last_heartbeat_at.present?
      assert_equal node.id, response.parsed_body.fetch("node_id")
    end

    test "local heartbeat updates the local node" do
      local_node = Node.create!(
        name: "Local",
        hostname: "local.test",
        local: true,
        last_heartbeat_at: 10.minutes.ago
      )

      post "/internal/nodes/heartbeat", params: { local: "true", capacity_cpu: "1.5" }

      assert_response :success
      assert_equal local_node.id, response.parsed_body.fetch("node_id")
      assert_equal BigDecimal("1.5"), local_node.reload.capacity_cpu
      assert local_node.last_heartbeat_at > 1.minute.ago
    end

    test "marks stale nodes unhealthy before recording heartbeat" do
      stale_node = Node.create!(
        name: "Stale",
        hostname: "stale.internal",
        status: "active",
        last_heartbeat_at: 10.minutes.ago
      )

      post "/internal/nodes/heartbeat", params: { name: "Fresh", hostname: "fresh.internal" }

      assert_response :success
      assert_equal "unhealthy", stale_node.reload.status
    end

    test "rejects heartbeat without token when internal token is configured" do
      ENV["PLATFORM_INTERNAL_TOKEN"] = "node-token"

      post "/internal/nodes/heartbeat", params: { name: "Worker", hostname: "worker.internal" }

      assert_response :unauthorized
      assert_nil Node.find_by(hostname: "worker.internal")
    end

    test "accepts heartbeat with configured token" do
      ENV["PLATFORM_INTERNAL_TOKEN"] = "node-token"

      post "/internal/nodes/heartbeat",
           params: { name: "Worker", hostname: "worker.internal" },
           headers: { "Authorization" => "Bearer node-token" }

      assert_response :success
      assert Node.exists?(hostname: "worker.internal")
    end
  end
end

require "test_helper"

module Admin
  class HealthControllerTest < ActionDispatch::IntegrationTest
    class FakeRuntimeAgent
      def initialize(available:)
        @available = available
      end

      def platform_available?
        @available
      end
    end

    setup do
      @admin = User.create!(email: "health-admin@example.com", password: "password123", admin: true)
      @owner = User.create!(email: "health-owner@example.com", password: "password123")
      @node = Node.create!(name: "Local", hostname: "health.test", local: true, last_heartbeat_at: 1.minute.ago)
      @hosted_app = @owner.apps.create!(name: "Health App", node: @node, status: "running")
      @hosted_app.record_event!("runtime.start_failed", "Container start failed")
    end

    test "admin sees platform health signals" do
      sign_in(@admin)

      with_runtime_agent(FakeRuntimeAgent.new(available: false)) do
        get admin_health_path
      end

      assert_response :success
      assert_select "h2", text: "Rails"
      assert_select "p", text: "Runtime agent cannot reach Docker."
      assert_select "h2", text: "Gateway"
      assert_select "h2", text: "Node heartbeat"
      assert_select "p", text: /1 app currently running/
      assert_select ".event-list strong", text: "runtime.start_failed"
    end

    private

    def sign_in(user)
      post "/sign_in", params: { email: user.email, password: "password123" }
    end

    def with_runtime_agent(agent)
      original = RuntimeAgent.method(:build)
      RuntimeAgent.define_singleton_method(:build) { agent }
      yield
    ensure
      RuntimeAgent.define_singleton_method(:build) { original.call }
    end
  end
end

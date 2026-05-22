require "test_helper"

module Admin
  class AppsControllerTest < ActionDispatch::IntegrationTest
    class FakeRuntimeAgent
      attr_reader :stopped_apps

      def initialize(result: RuntimeAgent::Result.success(command: "stop_app"))
        @result = result
        @stopped_apps = []
      end

      def stop_app(app)
        @stopped_apps << app
        @result
      end
    end

    setup do
      @admin = User.create!(email: "operator@example.com", password: "password123", admin: true)
      @owner = User.create!(email: "owner@example.com", password: "password123")
      @hosted_app = @owner.apps.create!(
        name: "Trouble App",
        status: "running",
        last_activity_at: 3.minutes.ago,
        memory_limit_bytes: 128.megabytes
      )
      runtime = @hosted_app.runtime_instances.create!(
        status: "running",
        container_id: "runtime-123",
        started_at: 5.minutes.ago
      )
      @hosted_app.runtime_metric_snapshots.create!(
        runtime_instance: runtime,
        memory_usage_bytes: 64.megabytes,
        cpu_usage_percent: 12.5
      )
    end

    test "admin sees all apps with owner status resources and stop action" do
      sign_in(@admin)

      get admin_apps_path

      assert_response :success
      assert_select "td", text: @owner.email
      assert_select ".status-running", text: "Running"
      assert_select "td", text: /64 MB/
      assert_select "form[action='#{stop_admin_app_path(@hosted_app)}']"
    end

    test "non-admin cannot access admin app overview" do
      sign_in(@owner)

      get admin_apps_path

      assert_response :not_found
    end

    test "admin can stop an app from overview" do
      sign_in(@admin)
      agent = FakeRuntimeAgent.new

      with_runtime_agent(agent) do
        post stop_admin_app_path(@hosted_app)
      end

      assert_redirected_to admin_apps_path
      assert_equal [ @hosted_app ], agent.stopped_apps
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

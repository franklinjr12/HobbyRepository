require "test_helper"

module Internal
  class GatewayControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @node = Node.create!(name: "Local", hostname: "local.test", local: true)
      @owner = User.create!(email: "gateway@example.com", password: "password123")
      @managed_app = App.create!(
        name: "Gateway App",
        slug: "gateway-app",
        owner: @owner,
        node: @node,
        image_reference: "example/gateway:latest",
        internal_port: 3000,
        status: "sleeping"
      )
      @managed_app.deployments.create!(image_reference: "example/gateway:latest", port: 3000, current: true)
      clear_enqueued_jobs
      clear_performed_jobs
    end

    teardown do
      clear_enqueued_jobs
      clear_performed_jobs
    end

    test "resolves unknown hostnames with safe not found response" do
      get "/internal/gateway/resolve", params: { hostname: "missing.example.test" }

      assert_response :not_found
      assert_equal "not_found", response.parsed_body.fetch("status")
    end

    test "identifies sleeping apps as wake required" do
      get "/internal/gateway/resolve", params: { hostname: @managed_app.default_route.hostname }

      assert_response :accepted
      body = response.parsed_body
      assert_equal "wake_required", body.fetch("status")
      assert_equal @managed_app.id, body.fetch("app_id")
      assert_equal "sleeping", body.fetch("app_status")
      assert_equal 3, body.fetch("retry_after")
    end

    test "returns internal target for running apps and records activity" do
      @managed_app.manual_override_to!("running", reason: "test running app")
      @managed_app.runtime_instances.create!(
        status: "running",
        container_id: "container-123",
        internal_host: "172.18.0.10",
        internal_port: 3000
      )

      get "/internal/gateway/resolve", params: { hostname: @managed_app.default_route.hostname }

      assert_response :success
      body = response.parsed_body
      assert_equal "running", body.fetch("status")
      assert_equal "http://172.18.0.10:3000", body.fetch("internal_target").fetch("url")
      assert @managed_app.reload.last_activity_at.present?
    end

    test "wake endpoint accepts app id, creates event, and enqueues one wake job" do
      assert_enqueued_with(job: WakeAppJob, args: [ @managed_app.id ]) do
        post "/internal/gateway/wake", params: { app_id: @managed_app.id }
      end

      assert_response :accepted
      body = response.parsed_body
      assert_equal "waking", body.fetch("status")
      assert_equal true, body.fetch("wake_enqueued")
      assert_equal "waking", @managed_app.reload.status
      assert_equal "gateway.wake_requested", @managed_app.app_events.order(:created_at).last.event_type
    end

    test "wake endpoint does not enqueue duplicates while wake is in progress" do
      @managed_app.manual_override_to!("waking", reason: "test wake already in progress")

      assert_no_enqueued_jobs do
        post "/internal/gateway/wake", params: { hostname: @managed_app.default_route.hostname }
      end

      assert_response :accepted
      body = response.parsed_body
      assert_equal "waking", body.fetch("status")
      assert_equal false, body.fetch("wake_enqueued")
    end

    test "wake status can be polled" do
      @managed_app.manual_override_to!("waking", reason: "test wake status")

      get "/internal/gateway/wake_status", params: { hostname: @managed_app.default_route.hostname }

      assert_response :success
      assert_equal "waking", response.parsed_body.fetch("status")
    end

    test "activity endpoint records last activity and event metadata" do
      post "/internal/gateway/activity", params: {
        app_id: @managed_app.id,
        hostname: @managed_app.default_route.hostname,
        request_method: "GET",
        path: "/docs"
      }

      assert_response :success
      assert_equal "recorded", response.parsed_body.fetch("status")
      assert @managed_app.reload.last_activity_at.present?
      event = @managed_app.app_events.order(:created_at).last
      assert_equal "gateway.activity_reported", event.event_type
      assert_equal "/docs", event.metadata.fetch("path")
    end
  end
end

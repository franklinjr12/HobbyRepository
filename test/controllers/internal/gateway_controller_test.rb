require "test_helper"

module Internal
  class GatewayControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @previous_internal_token = ENV["PLATFORM_INTERNAL_TOKEN"]
      ENV["PLATFORM_INTERNAL_TOKEN"] = nil
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
      @managed_app.deployments.create!(
        image_reference: "example/gateway:latest",
        port: 3000,
        current: true
      )
      clear_enqueued_jobs
      clear_performed_jobs
    end

    teardown do
      ENV["PLATFORM_INTERNAL_TOKEN"] = @previous_internal_token
      clear_enqueued_jobs
      clear_performed_jobs
    end

    def gateway_get(path, params: {}, token: nil)
      headers = { "Accept" => "application/json" }
      headers["Authorization"] = "Bearer #{token}" if token
      get path, params: params, headers: headers
    end

    def gateway_post(path, params: {}, token: nil)
      headers = { "Accept" => "application/json" }
      headers["Authorization"] = "Bearer #{token}" if token
      post path, params: params, headers: headers
    end

    test "rejects internal gateway requests without the platform token when configured" do
      ENV["PLATFORM_INTERNAL_TOKEN"] = "internal-test-token"
      log_output = StringIO.new
      logger = ActiveSupport::Logger.new(log_output)
      previous_logger = Rails.logger

      begin
        Rails.logger = logger
        assert_no_enqueued_jobs do
          gateway_post "/internal/gateway/wake", params: { app_id: @managed_app.id }
        end
      ensure
        Rails.logger = previous_logger
      end

      assert_response :unauthorized
      assert_equal "unauthorized", response.parsed_body.fetch("status")
      assert_equal "sleeping", @managed_app.reload.status
      assert_includes log_output.string, "Unauthorized internal gateway request"
      assert_includes log_output.string, "invalid internal token"
    end

    test "accepts internal gateway requests with the platform token" do
      ENV["PLATFORM_INTERNAL_TOKEN"] = "internal-test-token"

      gateway_get "/internal/gateway/resolve",
                  params: { hostname: @managed_app.default_route.hostname },
                  token: "internal-test-token"

      assert_response :accepted
      assert_equal "wake_required", response.parsed_body.fetch("status")
    end

    test "resolves unknown hostnames with safe not found response" do
      gateway_get "/internal/gateway/resolve", params: { hostname: "missing.example.test" }

      assert_response :not_found
      assert_equal "not_found", response.parsed_body.fetch("status")
      assert_not_includes response.body, "Gateway App"
    end

    test "renders generic platform page for browser unknown hostnames" do
      get "/internal/gateway/resolve",
          params: { hostname: "missing.example.test" },
          headers: { "Accept" => "text/html" }

      assert_response :not_found
      assert_includes response.media_type, "text/html"
      assert_select "h1", text: "App not found"
      assert_select "body", text: /missing.example.test/, count: 0
      assert_select "body", text: /Gateway App/, count: 0
    end

    test "identifies sleeping apps as wake required" do
      gateway_get "/internal/gateway/resolve",
                  params: { hostname: @managed_app.default_route.hostname }

      assert_response :accepted
      assert_equal "3", response.headers["Retry-After"]
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

      gateway_get "/internal/gateway/resolve",
                  params: { hostname: @managed_app.default_route.hostname }

      assert_response :success
      body = response.parsed_body
      assert_equal "running", body.fetch("status")
      assert_equal "http://172.18.0.10:3000", body.fetch("internal_target").fetch("url")
      assert @managed_app.reload.last_activity_at.present?
      assert @managed_app.last_request_at.present?
    end

    test "resolve returns api friendly failure for failed apps" do
      @managed_app.manual_override_to!("wake_failed", reason: "test failed wake")
      runtime_instance = @managed_app.runtime_instances.create!(
        status: "crashed",
        container_id: "container-500",
        failure_message: "Health check GET / timed out."
      )
      @managed_app.cold_start_metrics.create!(
        runtime_instance: runtime_instance,
        started_at: 1.minute.ago,
        finished_at: Time.current,
        status: "failed",
        total_wake_duration_ms: 60_000,
        failure_message: runtime_instance.failure_message
      )

      gateway_get "/internal/gateway/resolve",
                  params: { hostname: @managed_app.default_route.hostname }

      assert_response :bad_gateway
      body = response.parsed_body
      assert_equal "failed", body.fetch("status")
      assert_equal "timeout", body.fetch("reason")
      assert_equal "wake_failed", body.fetch("app_status")
      assert_not_includes response.body, runtime_instance.failure_message
    end

    test "resolve renders friendly wake failure page for browser users" do
      @managed_app.manual_override_to!("wake_failed", reason: "test failed wake")
      @managed_app.runtime_instances.create!(
        status: "crashed",
        container_id: "container-500",
        failure_message: "secret boot trace"
      )

      get "/internal/gateway/resolve",
          params: { hostname: @managed_app.default_route.hostname },
          headers: { "Accept" => "text/html" }

      assert_response :bad_gateway
      assert_select "h1", text: "App unavailable"
      assert_select "p", text: /Gateway App/
      assert_select "p", text: /Container crashed/
      assert_select "body", text: /secret boot trace/, count: 0
    end

    test "failure page links owner to dashboard when signed in" do
      @managed_app.manual_override_to!("wake_failed", reason: "test failed wake")
      post sign_in_path, params: { email: @owner.email, password: "password123" }

      get "/internal/gateway/resolve",
          params: { hostname: @managed_app.default_route.hostname },
          headers: { "Accept" => "text/html" }

      assert_response :bad_gateway
      assert_select "a[href='#{app_path(@managed_app)}']", text: "Open dashboard"
    end

    test "waking apps return retry after without html for json clients" do
      @managed_app.manual_override_to!("waking", reason: "test waking app")

      gateway_get "/internal/gateway/resolve",
                  params: { hostname: @managed_app.default_route.hostname }

      assert_response :accepted
      assert_equal "application/json", response.media_type
      assert_equal "3", response.headers["Retry-After"]
      assert_equal "wake_required", response.parsed_body.fetch("status")
    end

    test "wake endpoint accepts app id, creates event, and enqueues one wake job" do
      assert_enqueued_with(job: WakeAppJob, args: [ @managed_app.id ]) do
        gateway_post "/internal/gateway/wake", params: { app_id: @managed_app.id }
      end

      assert_response :accepted
      assert_equal "3", response.headers["Retry-After"]
      body = response.parsed_body
      assert_equal "waking", body.fetch("status")
      assert_equal true, body.fetch("wake_enqueued")
      assert_equal "waking", @managed_app.reload.status
      assert_equal(
        "gateway.wake_requested",
        @managed_app.app_events.order(:created_at).last.event_type
      )
    end

    test "wake endpoint does not enqueue duplicates while wake is in progress" do
      @managed_app.manual_override_to!("waking", reason: "test wake already in progress")

      assert_no_enqueued_jobs do
        gateway_post "/internal/gateway/wake",
                     params: { hostname: @managed_app.default_route.hostname }
      end

      assert_response :accepted
      body = response.parsed_body
      assert_equal "waking", body.fetch("status")
      assert_equal false, body.fetch("wake_enqueued")
    end

    test "wake status can be polled" do
      @managed_app.manual_override_to!("waking", reason: "test wake status")

      gateway_get "/internal/gateway/wake_status",
                  params: { hostname: @managed_app.default_route.hostname }

      assert_response :success
      assert_equal "waking", response.parsed_body.fetch("status")
      assert_equal "3", response.headers["Retry-After"]
    end

    test "wake status reports failed apps with broad reason" do
      @managed_app.manual_override_to!("wake_failed", reason: "test failed wake")
      @managed_app.record_event!(
        "runtime.start_failed",
        "Container start failed",
        metadata: { error: { code: "image_unavailable", message: "private registry secret" } }
      )

      gateway_get "/internal/gateway/wake_status",
                  params: { hostname: @managed_app.default_route.hostname }

      assert_response :bad_gateway
      body = response.parsed_body
      assert_equal "failed", body.fetch("status")
      assert_equal "image_pull_failed", body.fetch("reason")
      assert_not_includes response.body, "private registry secret"
    end

    test "activity endpoint records last activity and event metadata" do
      assert_difference -> { @managed_app.app_request_metrics.count }, 1 do
        gateway_post "/internal/gateway/activity", params: {
          app_id: @managed_app.id,
          hostname: @managed_app.default_route.hostname,
          event: "request_started",
          request_method: "GET",
          path: "/docs",
          status_code: 200,
          cold_start: "false"
        }
      end

      assert_response :success
      assert_equal "recorded", response.parsed_body.fetch("status")
      assert @managed_app.reload.last_activity_at.present?
      assert_equal 1, @managed_app.active_request_count
      event = @managed_app.app_events.order(:created_at).last
      assert_equal "gateway.activity_reported", event.event_type
      assert_equal "/docs", event.metadata.fetch("path")
      metric = @managed_app.app_request_metrics.last
      assert_equal 200, metric.status_code
      assert_equal "GET", metric.request_method
      assert_not metric.cold_start?
    end

    test "wake endpoint records a cold request metric" do
      assert_difference -> { @managed_app.app_request_metrics.cold_starts.count }, 1 do
        gateway_post "/internal/gateway/wake", params: {
          app_id: @managed_app.id,
          request_method: "GET",
          path: "/"
        }
      end

      assert_response :accepted
      assert_equal "/", @managed_app.app_request_metrics.last.path
    end

    test "activity endpoint records request finish without negative counters" do
      @managed_app.update!(active_request_count: 1, active_connection_count: 1)

      gateway_post "/internal/gateway/activity", params: {
        app_id: @managed_app.id,
        event: "request_finished",
        connection: true
      }

      assert_response :success
      assert_equal 0, @managed_app.reload.active_request_count
      assert_equal 0, @managed_app.active_connection_count
    end
  end
end

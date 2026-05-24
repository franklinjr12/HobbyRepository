require "test_helper"

class ColdRequestFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  class FakeRuntimeAgent
    def start_app(app)
      runtime_instance = app.runtime_instances.create!(
        status: "running",
        container_id: "container-#{app.id}",
        internal_host: "172.18.0.20",
        internal_port: app.internal_port
      )
      app.manual_override_to!("running", reason: "test wake completed")
      app.cold_start_metrics.create!(
        runtime_instance: runtime_instance,
        started_at: 2.seconds.ago,
        finished_at: Time.current,
        status: "succeeded",
        total_wake_duration_ms: 2_000
      )
      RuntimeAgent::Result.success(command: "start_app", runtime_instance_id: runtime_instance.id)
    end

    def stop_app(app)
      app.runtime_instances.where(status: "running").find_each do |runtime_instance|
        runtime_instance.update!(status: "stopped", stopped_at: Time.current)
      end
      app.manual_override_to!("stopped", reason: "test idle stop")
      RuntimeAgent::Result.success(command: "stop_app")
    end
  end

  setup do
    @previous_internal_token = ENV["PLATFORM_INTERNAL_TOKEN"]
    ENV["PLATFORM_INTERNAL_TOKEN"] = nil
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @owner = User.create!(email: "cold-flow@example.com", password: "password123")
    @managed_app = @owner.apps.create!(
      name: "Cold Flow App",
      slug: "cold-flow-app",
      node: @node,
      image_reference: "example/cold-flow:latest",
      internal_port: 3000,
      idle_timeout_seconds: 300,
      status: "sleeping"
    )
    @managed_app.deployments.create!(image_reference: "example/cold-flow:latest", port: 3000, current: true)
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    ENV["PLATFORM_INTERNAL_TOKEN"] = @previous_internal_token
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "cold request wakes app, resolves target, records traffic, and sleeps after idle timeout" do
    get "/internal/gateway/resolve", params: { hostname: @managed_app.default_route.hostname }

    assert_response :accepted
    assert_equal "wake_required", response.parsed_body.fetch("status")

    assert_enqueued_with(job: WakeAppJob, args: [ @managed_app.id ]) do
      post "/internal/gateway/wake", params: {
        app_id: @managed_app.id,
        request_method: "GET",
        path: "/"
      }
    end

    assert_response :accepted
    assert_equal "waking", @managed_app.reload.status

    with_runtime_agent(FakeRuntimeAgent.new) do
      perform_enqueued_jobs(only: WakeAppJob)
    end

    assert_equal "running", @managed_app.reload.status

    get "/internal/gateway/resolve", params: { hostname: @managed_app.default_route.hostname }

    assert_response :success
    assert_equal "http://172.18.0.20:3000", response.parsed_body.fetch("internal_target").fetch("url")

    post "/internal/gateway/activity", params: {
      app_id: @managed_app.id,
      event: "request_finished",
      request_method: "GET",
      path: "/",
      status_code: 200,
      cold_start: "true",
      wake_duration_ms: 2_000
    }

    assert_response :success
    assert_equal 2, @managed_app.reload.app_request_metrics.count
    assert_equal 2, @managed_app.app_request_metrics.cold_starts.count

    @managed_app.update!(last_request_at: 10.minutes.ago, last_activity_at: 10.minutes.ago)

    with_runtime_agent(FakeRuntimeAgent.new) do
      IdleSleepJob.perform_now
    end

    assert_equal "sleeping", @managed_app.reload.status
    assert_includes @managed_app.app_events.pluck(:event_type), "sleep.succeeded"
  end

  private

  def with_runtime_agent(agent)
    original = RuntimeAgent.method(:build)
    RuntimeAgent.define_singleton_method(:build) { agent }
    yield
  ensure
    RuntimeAgent.define_singleton_method(:build) { original.call }
  end
end

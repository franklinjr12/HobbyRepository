require "test_helper"

class IdleSleepJobTest < ActiveJob::TestCase
  class FakeRuntimeAgent
    def stop_app(app)
      app.manual_override_to!("stopped", reason: "test idle stop")
      RuntimeAgent::Result.success(command: "stop_app")
    end
  end

  setup do
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @owner = User.create!(email: "idle-job@example.com", password: "password123")
  end

  def with_runtime_agent(agent)
    original = RuntimeAgent.method(:build)
    RuntimeAgent.define_singleton_method(:build) { agent }
    yield
  ensure
    RuntimeAgent.define_singleton_method(:build) { original.call }
  end

  test "sleeps running apps after their idle timeout" do
    app = @owner.apps.create!(
      name: "Idle Runner",
      slug: "idle-runner",
      node: @node,
      status: "sleeping",
      idle_timeout_seconds: 300,
      last_request_at: 10.minutes.ago
    )
    app.manual_override_to!("running", reason: "test running idle app")

    with_runtime_agent(FakeRuntimeAgent.new) do
      IdleSleepJob.perform_now
    end

    assert_equal "sleeping", app.reload.status
    assert_includes app.app_events.pluck(:event_type), "sleep.succeeded"
  end

  test "leaves active running apps alone" do
    app = @owner.apps.create!(
      name: "Busy Runner",
      slug: "busy-runner",
      node: @node,
      status: "sleeping",
      idle_timeout_seconds: 300,
      last_request_at: 1.minute.ago,
      active_request_count: 1
    )
    app.manual_override_to!("running", reason: "test running busy app")

    with_runtime_agent(FakeRuntimeAgent.new) do
      IdleSleepJob.perform_now
    end

    assert_equal "running", app.reload.status
    assert_not_includes app.app_events.pluck(:event_type), "sleep.succeeded"
  end

  test "leaves always-on idle apps running" do
    app = @owner.apps.create!(
      name: "Always On Runner",
      slug: "always-on-runner",
      node: @node,
      status: "sleeping",
      sleep_mode: "always_on",
      idle_timeout_seconds: 300,
      last_request_at: 10.minutes.ago
    )
    app.manual_override_to!("running", reason: "test always-on idle app")

    with_runtime_agent(FakeRuntimeAgent.new) do
      IdleSleepJob.perform_now
    end

    assert_equal "running", app.reload.status
    assert_not_includes app.app_events.pluck(:event_type), "sleep.succeeded"
  end

  test "marks idle active apps as draining before stopping them" do
    app = @owner.apps.create!(
      name: "Active Idle Runner",
      slug: "active-idle-runner",
      node: @node,
      status: "sleeping",
      idle_timeout_seconds: 300,
      last_request_at: 10.minutes.ago,
      active_request_count: 1
    )
    app.manual_override_to!("running", reason: "test running active idle app")

    with_runtime_agent(FakeRuntimeAgent.new) do
      IdleSleepJob.perform_now
    end

    assert_equal "draining", app.reload.status
    assert_includes app.app_events.pluck(:event_type), "sleep.started"
    assert_not_includes app.app_events.pluck(:event_type), "sleep.succeeded"
  end

  test "forces draining apps to sleep after drain timeout" do
    app = @owner.apps.create!(
      name: "Long Request Runner",
      slug: "long-request-runner",
      node: @node,
      status: "sleeping",
      active_request_count: 1,
      drain_started_at: 1.minute.ago
    )
    app.manual_override_to!("draining", reason: "test drain timeout")

    with_runtime_agent(FakeRuntimeAgent.new) do
      IdleSleepJob.perform_now
    end

    assert_equal "sleeping", app.reload.status
    assert_includes app.app_events.pluck(:event_type), "sleep.succeeded"
  end
end

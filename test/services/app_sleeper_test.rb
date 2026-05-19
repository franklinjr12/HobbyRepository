require "test_helper"

class AppSleeperTest < ActiveSupport::TestCase
  class FakeRuntimeAgent
    attr_reader :stopped_apps

    def initialize(result: RuntimeAgent::Result.success(command: "stop_app"))
      @result = result
      @stopped_apps = []
    end

    def stop_app(app)
      stopped_apps << app
      app.manual_override_to!("stopped", reason: "test stop")
      @result
    end
  end

  setup do
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @owner = User.create!(email: "sleeper@example.com", password: "password123")
    @app = App.create!(name: "Sleepable", slug: "sleepable", owner: @owner, node: @node, status: "sleeping")
    @app.manual_override_to!("running", reason: "test running app")
  end

  test "sleeps a running app and records sleep events" do
    agent = FakeRuntimeAgent.new

    result = AppSleeper.new(runtime_agent: agent).sleep(
      @app,
      requested_by: "owner@example.com",
      trigger: "manual_dashboard"
    )

    assert result.success?
    assert_equal "sleeping", @app.reload.status
    assert_equal [ @app ], agent.stopped_apps
    assert_includes @app.app_events.pluck(:event_type), "sleep.started"
    assert_equal "sleep.succeeded", @app.app_events.order(:created_at).last.event_type
  end

  test "refuses idle sleep while requests are active" do
    @app.update!(active_request_count: 1)
    agent = FakeRuntimeAgent.new

    result = AppSleeper.new(runtime_agent: agent).sleep(
      @app,
      requested_by: "platform",
      trigger: "idle_timeout"
    )

    assert_not result.success?
    assert_equal "active_requests", result.error.code
    assert_empty agent.stopped_apps
    assert_equal "running", @app.reload.status
  end
end

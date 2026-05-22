require "test_helper"

class RuntimeReconcilerTest < ActiveSupport::TestCase
  class FakeRuntimeAgent
    def initialize(containers)
      @containers = containers
    end

    def list_platform_containers
      RuntimeAgent::Result.success(containers: @containers)
    end
  end

  setup do
    @owner = User.create!(email: "reconcile@example.com", password: "password123")
    @app = @owner.apps.create!(name: "Reconcile App", status: "running")
  end

  test "marks active runtime instances missing when their containers disappeared" do
    runtime = @app.runtime_instances.create!(status: "running", container_id: "gone-123")

    result = RuntimeReconciler.new(runtime_agent: FakeRuntimeAgent.new([])).reconcile!

    assert_equal [ runtime.id ], result.missing_runtime_ids
    assert_equal "missing", runtime.reload.status
    assert_equal "crashed", @app.reload.status
    assert_equal "runtime.recovery_missing", @app.app_events.order(:created_at).last.event_type
  end

  test "creates orphaned runtime records for active unknown containers tied to an app" do
    container = {
      container_id: "orphan-123",
      state: "running",
      status: "Up 2 minutes",
      labels: { RuntimeAgent::LABEL_APP_ID => @app.id.to_s }
    }

    assert_difference -> { @app.runtime_instances.count }, 1 do
      result = RuntimeReconciler.new(runtime_agent: FakeRuntimeAgent.new([ container ])).reconcile!

      assert_equal [ "orphan-123" ], result.orphaned_container_ids
    end

    runtime = @app.runtime_instances.order(:created_at).last
    assert_equal "orphaned", runtime.status
    assert_equal "orphan-123", runtime.container_id
    assert_equal "runtime.recovery_orphaned", @app.app_events.order(:created_at).last.event_type
  end

  test "syncs known running containers so apps are remembered after restart" do
    @app.manual_override_to!("waking", reason: "test restart state")
    runtime = @app.runtime_instances.create!(status: "starting", container_id: "known-123")
    container = {
      container_id: "known-123",
      state: "running",
      labels: { RuntimeAgent::LABEL_APP_ID => @app.id.to_s }
    }

    result = RuntimeReconciler.new(runtime_agent: FakeRuntimeAgent.new([ container ])).reconcile!

    assert_equal 1, result.checked_containers
    assert_equal "running", runtime.reload.status
    assert_equal "running", @app.reload.status
    assert_equal "runtime.recovery_synced", @app.app_events.order(:created_at).last.event_type
  end
end

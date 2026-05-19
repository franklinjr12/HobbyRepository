require "test_helper"

class AppTest < ActiveSupport::TestCase
  setup do
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @owner = User.create!(email: "owner@example.com", password: "password123")
  end

  test "assigns defaults and local node for new app" do
    app = App.create!(name: "Tiny Site", slug: "Tiny Site", owner: @owner)

    assert_equal @node, app.node
    assert_equal @owner, app.owner
    assert_equal "tiny-site", app.slug
    assert_equal "created", app.status
    assert_equal 900, app.idle_timeout_seconds
    assert_equal 60, app.startup_timeout_seconds
    assert_equal "http", app.health_check_kind
    assert_equal "/", app.health_check_path
    assert_equal "tiny-site.localhost", app.default_route.hostname
    assert_equal [ "app.created" ], app.app_events.pluck(:event_type)
  end

  test "allows port readiness without a health check path" do
    app = App.create!(
      name: "Port Ready",
      slug: "port-ready",
      owner: @owner,
      node: @node,
      health_check_kind: "port",
      health_check_path: nil
    )

    assert app.valid?
    assert_nil app.health_check_path
  end

  test "requires http health checks to use an absolute path" do
    app = App.new(
      name: "Bad Health",
      slug: "bad-health",
      owner: @owner,
      node: @node,
      health_check_kind: "http",
      health_check_path: "ready"
    )

    assert_not app.valid?
    assert_includes app.errors[:health_check_path], "must start with /"
  end

  test "requires an owner" do
    app = App.new(name: "Ownerless", slug: "ownerless", node: @node)

    assert_not app.valid?
    assert_includes app.errors[:owner], "must exist"
  end

  test "returns current deployment" do
    app = App.create!(name: "Deployable", slug: "deployable", owner: @owner, node: @node)
    old_deployment = app.deployments.create!(image_reference: "example/old:1", port: 3000)
    current_deployment = app.deployments.create!(
      image_reference: "example/new:2",
      port: 3000,
      current: true
    )

    assert_equal current_deployment, app.current_deployment
    assert_not old_deployment.current?
  end

  test "allows valid lifecycle transitions" do
    app = App.create!(name: "Wakeable", slug: "wakeable", owner: @owner, node: @node, status: "sleeping")

    assert app.may_transition_to?("waking")

    app.transition_to!("waking")
    app.transition_to!("running")

    assert_equal "running", app.status
  end

  test "rejects inconsistent lifecycle jumps" do
    app = App.create!(name: "Jumping", slug: "jumping", owner: @owner, node: @node, status: "sleeping")

    assert_not app.update(status: "running")
    assert_includes app.errors[:status], "cannot transition from sleeping to running"
  end

  test "manual override can repair app state with a reason" do
    app = App.create!(name: "Repairable", slug: "repairable", owner: @owner, node: @node, status: "sleeping")

    app.manual_override_to!("running", reason: "operator verified runtime")

    assert_equal "running", app.status
  end

  test "restore after restart conservatively clears active states" do
    app = App.create!(name: "Restarted", slug: "restarted", owner: @owner, node: @node, status: "sleeping")
    app.transition_to!("waking")
    app.transition_to!("running")

    app.restore_status_after_platform_restart!

    assert_equal "sleeping", app.status
  end

  test "builds runtime environment payload without masking runtime secrets" do
    app = App.create!(name: "Configured", slug: "configured", owner: @owner, node: @node)
    app.environment_variables.create!(key: "DATABASE_URL", value: "postgres://example", secret: true)
    app.environment_variables.create!(key: "RAILS_ENV", value: "production")

    assert_equal(
      {
        "DATABASE_URL" => "postgres://example",
        "RAILS_ENV" => "production"
      },
      app.runtime_environment
    )
  end

  test "records runtime environment event metadata without values" do
    app = App.create!(name: "Runtime Env", slug: "runtime-env", owner: @owner, node: @node)
    app.environment_variables.create!(key: "API_TOKEN", value: "secret-token", secret: true)

    app.record_runtime_environment_prepared!

    event = app.app_events.order(:created_at).last
    assert_equal "runtime.environment_prepared", event.event_type
    assert_equal 1, event.metadata.fetch("variable_count")
    assert_equal 1, event.metadata.fetch("secret_count")
    assert_equal [ "API_TOKEN" ], event.metadata.fetch("keys")
    assert_no_match "secret-token", event.metadata.to_json
  end

  test "tracks active request and connection activity" do
    app = App.create!(name: "Active App", slug: "active-app", owner: @owner, node: @node, status: "sleeping")
    app.manual_override_to!("running", reason: "test active runtime")

    app.record_request_started!(connection: true)

    assert_equal 1, app.reload.active_request_count
    assert_equal 1, app.active_connection_count
    assert app.last_request_at.present?
    assert app.active_runtime_activity?

    app.record_request_finished!(connection: true)

    assert_equal 0, app.reload.active_request_count
    assert_equal 0, app.active_connection_count
  end

  test "idle sleep is due only for inactive running apps past timeout" do
    app = App.create!(
      name: "Idle App",
      slug: "idle-app",
      owner: @owner,
      node: @node,
      status: "sleeping",
      idle_timeout_seconds: 300,
      last_request_at: 10.minutes.ago
    )
    app.manual_override_to!("running", reason: "test running idle app")

    assert app.idle_sleep_due?

    app.update!(active_request_count: 1)

    assert_not app.idle_sleep_due?
    assert app.idle_timeout_reached?
  end

  test "new request cancels draining sleep decision" do
    app = App.create!(name: "Draining App", slug: "draining-app", owner: @owner, node: @node, status: "sleeping")
    app.manual_override_to!("running", reason: "test running app")
    app.begin_sleep_drain!(requested_by: "platform", trigger: "idle_timeout")

    app.record_request_started!

    assert_equal "running", app.reload.status
    assert_equal "sleep.cancelled", app.app_events.order(:created_at).last.event_type
  end
end

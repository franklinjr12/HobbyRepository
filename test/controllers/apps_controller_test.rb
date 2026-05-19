require "test_helper"

class AppsControllerTest < ActionDispatch::IntegrationTest
  class FakeRuntimeAgent
    def initialize(start_result: nil, stop_result: nil)
      @start_result = start_result
      @stop_result = stop_result
    end

    def start_app(app)
      return @start_result if @start_result

      app.manual_override_to!("waking", reason: "test runtime start")
      app.record_event!("runtime.start_succeeded", "Container start requested")
      RuntimeAgent::Result.success(command: "start_app")
    end

    def stop_app(app)
      return @stop_result if @stop_result

      app.manual_override_to!("stopped", reason: "test runtime stop")
      app.record_event!("runtime.stop_succeeded", "Container stopped")
      RuntimeAgent::Result.success(command: "stop_app")
    end
  end

  class FakeProvisioner
    def provision(database_resource)
      database_resource.mark_provisioned!
      DatabaseResourceProvisioner::Result.new(true, "Database provisioned.")
    end
  end

  class FakeBackupExporter
    def export(database_resource)
      backup = database_resource.database_backups.create!
      backup.mark_completed!("-- Database: #{database_resource.database_name}\n")
      database_resource.app.record_event!(
        "database.backup_completed",
        "Database backup completed for #{database_resource.app.name}",
        metadata: backup.public_metadata
      )
      DatabaseBackupExporter::Result.new(true, "Database backup completed.", backup)
    end
  end

  setup do
    @user = User.create!(email: "apps@example.com", password: "password123")
    Node.ensure_local!
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  def with_runtime_agent(agent)
    original = RuntimeAgent.method(:build)
    RuntimeAgent.define_singleton_method(:build) { agent }
    yield
  ensure
    RuntimeAgent.define_singleton_method(:build) { original.call }
  end

  def with_database_provisioner(provisioner)
    original = DatabaseResourceProvisioner.method(:new)
    DatabaseResourceProvisioner.define_singleton_method(:new) { provisioner }
    yield
  ensure
    DatabaseResourceProvisioner.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def with_database_backup_exporter(exporter)
    original = DatabaseBackupExporter.method(:new)
    DatabaseBackupExporter.define_singleton_method(:new) { exporter }
    yield
  ensure
    DatabaseBackupExporter.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  test "creates app with default route, current deployment, and events" do
    assert_difference -> { App.count }, 1 do
      assert_difference -> { Route.count }, 1 do
        assert_difference -> { Deployment.count }, 1 do
          assert_difference -> { Volume.count }, 1 do
            assert_difference -> { DatabaseResource.count }, 1 do
              post apps_path, params: {
                app: {
                  name: "Tiny Service",
                  image_reference: "example/tiny:latest",
                  internal_port: 3000,
                  idle_timeout_seconds: 900,
                  health_check_kind: "http",
                  health_check_path: "/up",
                  volume_enabled: "1",
                  volume_mount_path: "/data",
                  database_enabled: "1",
                  database_type: "postgres"
                }
              }
            end
          end
        end
      end
    end

    app = @user.apps.find_by!(slug: "tiny-service")
    assert_redirected_to app_path(app)
    assert_equal "tiny-service.localhost", app.default_route.hostname
    assert_equal "example/tiny:latest", app.current_deployment.image_reference
    assert_equal "http", app.current_deployment.health_check_kind
    assert_equal "/up", app.current_deployment.health_check_path
    assert_equal "/data", app.volume.mount_path
    assert_equal "pending", app.database_resource.status
    assert_equal %w[volume.created database.created app.created deployment.created], app.app_events.order(:created_at).pluck(:event_type)
  end

  test "index shows owned app management details" do
    app = @user.apps.create!(
      name: "Visible App",
      image_reference: "example/visible:latest",
      internal_port: 3000,
      last_activity_at: 5.minutes.ago,
      status: "sleeping"
    )
    app.deployments.create!(image_reference: "example/visible:latest", port: 3000, current: true)

    get apps_path

    assert_response :success
    assert_select "td", text: "Sleeping"
    assert_select "a[href='http://#{app.default_route.hostname}']", text: app.default_route.hostname
    assert_select "td", text: /example\/visible:latest/
    assert_select "form[action='#{wake_app_path(app)}']"
    assert_select "form[action='#{sleep_app_path(app)}']"
  end

  test "show includes configuration, runtime, routes, events, and log signal" do
    app = @user.apps.create!(
      name: "Detailed App",
      image_reference: "example/detailed:latest",
      internal_port: 3000,
      status: "running"
    )
    app.deployments.create!(image_reference: "example/detailed:latest", port: 3000, current: true)
    app.runtime_instances.create!(
      status: "crashed",
      container_id: "abc123",
      failure_message: "boot failed"
    )
    app.app_logs.create!(
      runtime_instance: app.runtime_instances.last,
      deployment: app.current_deployment,
      stream: "stderr",
      logged_at: 1.minute.ago,
      message: "boot failed"
    )
    app.record_event!("health_check.failed", "Health check failed")

    get app_path(app)

    assert_response :success
    assert_select "h2", text: "Configuration"
    assert_select "h2", text: "Runtime Instance"
    assert_select "dt", text: "Health check result"
    assert_select "h2", text: "Routes"
    assert_select "form[action='#{inspect_runtime_app_path(app)}']"
    assert_select "a[href='#{app_app_logs_path(app)}']", text: "Logs"
    assert_select "pre", text: /stderr: boot failed/
    assert_select ".event-list strong", text: "health_check.failed"
  end

  test "show masks secret environment variable values" do
    app = @user.apps.create!(name: "Secret App", image_reference: "example/secret:latest", internal_port: 3000)
    app.environment_variables.create!(key: "API_TOKEN", value: "super-secret", secret: true)
    app.environment_variables.create!(key: "PUBLIC_MODE", value: "demo")

    get app_path(app)

    assert_response :success
    assert_select "h2", text: "Environment Variables"
    assert_select "code", text: "********"
    assert_select "code", text: "demo"
    assert_select "body", text: /super-secret/, count: 0
  end

  test "show includes persistent storage details" do
    app = @user.apps.create!(name: "Storage App", image_reference: "example/storage:latest", internal_port: 3000)
    app.create_volume!(mount_path: "/app/data")

    get app_path(app)

    assert_response :success
    assert_select "h2", text: "Persistent Storage"
    assert_select "dt", text: "Mount path"
    assert_select "code", text: "/app/data"
  end

  test "show includes shared database details without secret values" do
    app = @user.apps.create!(name: "Database App", image_reference: "example/db:latest", internal_port: 3000)
    database_resource = app.create_database_resource!(status: "available")

    get app_path(app)

    assert_response :success
    assert_select "h2", text: "Shared Database"
    assert_select "code", text: "DATABASE_URL, DATABASE_NAME, DATABASE_USERNAME, DATABASE_PASSWORD, DATABASE_HOST, DATABASE_PORT"
    assert_select "code", text: "********"
    assert_select "body", text: /#{Regexp.escape(database_resource.password)}/, count: 0
  end

  test "manual database actions provision rotate and back up credentials" do
    app = @user.apps.create!(name: "Database Actions", image_reference: "example/db:latest", internal_port: 3000)

    with_database_provisioner(FakeProvisioner.new) do
      post provision_database_app_path(app)
    end

    assert_redirected_to app_path(app)
    assert_equal "available", app.reload.database_resource.status

    original_password = app.database_resource.password
    post rotate_database_credentials_app_path(app)

    assert_redirected_to app_path(app)
    assert_not_equal original_password, app.reload.database_resource.password

    with_database_backup_exporter(FakeBackupExporter.new) do
      assert_difference -> { DatabaseBackup.count }, 1 do
        post backup_database_app_path(app)
      end
    end

    backup = app.database_resource.database_backups.last
    assert_redirected_to app_path(app)
    assert_equal "completed", backup.status
    assert_includes app.app_events.pluck(:event_type), "database.backup_completed"

    get app_database_backup_path(app, backup)

    assert_response :success
    assert_match "Database: #{app.database_resource.database_name}", response.body
    assert_not_includes response.body, app.database_resource.password
  end

  test "settings update can create replacement deployment" do
    app = @user.apps.create!(
      name: "Editable App",
      image_reference: "example/old:latest",
      internal_port: 3000
    )
    original_deployment = app.deployments.create!(
      image_reference: "example/old:latest",
      port: 3000,
      current: true
    )

    assert_difference -> { Deployment.count }, 1 do
      patch app_path(app), params: {
        app: {
          name: "Editable App",
          image_reference: "example/new:latest",
          internal_port: 4000,
          health_check_kind: "port",
          health_check_path: "/ready",
          idle_timeout_seconds: 120,
          startup_timeout_seconds: 30,
          memory_limit_bytes: 268_435_456,
          cpu_limit: 0.5,
          volume_enabled: "1",
          volume_mount_path: "/cache",
          database_enabled: "1",
          database_type: "postgres"
        }
      }
    end

    app.reload
    assert_redirected_to app_path(app)
    assert_equal "example/new:latest", app.current_deployment.image_reference
    assert_equal 4000, app.current_deployment.port
    assert_equal "port", app.current_deployment.health_check_kind
    assert_nil app.current_deployment.health_check_path
    assert_equal "/cache", app.volume.mount_path
    assert_equal "pending", app.database_resource.status
    assert_not original_deployment.reload.current?
    assert_includes app.app_events.order(:created_at).pluck(:event_type), "app.updated"
  end

  test "settings update can disable an active volume mount" do
    app = @user.apps.create!(name: "Disable Storage", image_reference: "example/app:latest", internal_port: 3000)
    app.create_volume!(mount_path: "/data")

    patch app_path(app), params: {
      app: {
        name: "Disable Storage",
        image_reference: "example/app:latest",
        internal_port: 3000,
        health_check_path: "/",
        idle_timeout_seconds: 900,
        volume_enabled: "0",
        volume_mount_path: "/data"
      }
    }

    assert_redirected_to app_path(app)
    assert_equal "disabled", app.volume.reload.status
    assert_includes app.app_events.order(:created_at).pluck(:event_type), "volume.disabled"
  end

  test "settings update rejects invalid runtime configuration" do
    app = @user.apps.create!(name: "Invalid Edit", image_reference: "example/app:latest", internal_port: 3000)

    patch app_path(app), params: {
      app: {
        name: "Invalid Edit",
        image_reference: "example/app:latest",
        internal_port: 70_000,
        health_check_path: "/",
        idle_timeout_seconds: 30
      }
    }

    assert_response :unprocessable_content
    assert_select ".error-panel"
  end

  test "manual wake and sleep update state and record events" do
    app = @user.apps.create!(name: "Manual App", status: "sleeping")

    with_runtime_agent(FakeRuntimeAgent.new) do
      post wake_app_path(app)
    end
    assert_redirected_to app_path(app)
    assert_equal "waking", app.reload.status
    assert_equal "runtime.start_succeeded", app.app_events.order(:created_at).last.event_type

    app.manual_override_to!("running", reason: "test running before manual sleep")
    app.runtime_instances.create!(status: "running", container_id: "manual-container")

    with_runtime_agent(FakeRuntimeAgent.new) do
      post sleep_app_path(app)
    end
    assert_redirected_to app_path(app)
    assert_equal "sleeping", app.reload.status
    assert_equal "sleep.succeeded", app.app_events.order(:created_at).last.event_type
  end

  test "manual wake shows normalized runtime failures" do
    app = @user.apps.create!(name: "Broken App", status: "sleeping")
    error = RuntimeAgent::Error.new("start_failed", "Container start failed", [ "docker", "run" ], 1, "boom", {})

    with_runtime_agent(FakeRuntimeAgent.new(start_result: RuntimeAgent::Result.failure(error))) do
      post wake_app_path(app)
    end

    assert_redirected_to app_path(app)
    assert_equal "Container start failed", flash[:alert]
  end

  test "does not show another user's app" do
    other_user = User.create!(email: "other@example.com", password: "password123")
    app = other_user.apps.create!(name: "Private", slug: "private")

    get app_path(app)

    assert_response :not_found
  end

  test "does not update another user's app" do
    other_user = User.create!(email: "other-update@example.com", password: "password123")
    app = other_user.apps.create!(name: "Private Update", slug: "private-update")

    patch app_path(app), params: { app: { name: "Taken" } }

    assert_response :not_found
    assert_equal "Private Update", app.reload.name
  end
end

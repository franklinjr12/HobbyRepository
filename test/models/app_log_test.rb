require "test_helper"

class AppLogTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "logs@example.com", password: "password123")
    @app = @owner.apps.create!(name: "Log App", image_reference: "example/log:latest", internal_port: 3000)
    @deployment = @app.deployments.create!(image_reference: "example/log:latest", port: 3000, current: true)
    @runtime_instance = @app.runtime_instances.create!(
      status: "running",
      container_id: "container-logs",
      deployment: @deployment
    )
  end

  test "ingests docker stdout and stderr with timestamps" do
    assert_difference -> { AppLog.count }, 2 do
      AppLog.ingest_docker_output!(
        app: @app,
        runtime_instance: @runtime_instance,
        stdout: "2026-05-19T12:00:00.000000000Z booted\n",
        stderr: "2026-05-19T12:00:01.000000000Z warned\n"
      )
    end

    assert_equal %w[stdout stderr], @app.app_logs.order(:logged_at).pluck(:stream)
    assert_equal "booted", @app.app_logs.order(:logged_at).first.message
    assert_equal @deployment, @app.app_logs.first.deployment
  end

  test "deduplicates repeated docker log lines" do
    output = "2026-05-19T12:00:00.000000000Z booted\n"

    assert_difference -> { AppLog.count }, 1 do
      2.times do
        AppLog.ingest_docker_output!(
          app: @app,
          runtime_instance: @runtime_instance,
          stdout: output,
          stderr: ""
        )
      end
    end
  end
end

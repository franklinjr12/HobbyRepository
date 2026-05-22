require "test_helper"

module RuntimeAgent
  class LocalDockerAgentTest < ActiveSupport::TestCase
    class FakeRunner
      attr_reader :commands

      def initialize(responses)
        @responses = responses
        @commands = []
      end

      def call(command)
        @commands << command
        @responses.shift || success
      end

      def self.success(stdout = "")
        DockerRunner::CommandResult.new(stdout, "", 0)
      end

      def self.failure(stderr = "failed", exit_status = 1)
        DockerRunner::CommandResult.new("", stderr, exit_status)
      end

      private

      def success
        self.class.success
      end
    end

    class FakeHealthChecker
      def initialize(result)
        @result = result
      end

      def wait_until_ready(deployment:, runtime_instance:, timeout_seconds:)
        @result
      end
    end

    setup do
      @node = Node.create!(name: "Local", hostname: "local.test", local: true)
      @owner = User.create!(email: "agent@example.com", password: "password123")
      @app = App.create!(
        name: "Agent App",
        slug: "agent-app",
        owner: @owner,
        node: @node,
        image_reference: "example/agent:latest",
        internal_port: 3000,
        memory_limit_bytes: 134_217_728,
        cpu_limit: 0.5,
        status: "sleeping"
      )
      @deployment = @app.deployments.create!(
        image_reference: "example/agent:latest",
        port: 3000,
        current: true
      )
      @app.environment_variables.create!(key: "RAILS_ENV", value: "production")
      @database_resource = @app.create_database_resource!(status: "available")
      @app.create_volume!(mount_path: "/app/data")
    end

    test "starts an app container through one normalized command boundary" do
      runner = FakeRunner.new([
        FakeRunner.success,
        FakeRunner.success,
        FakeRunner.success("container-123\n")
      ])
      agent = LocalDockerAgent.new(runner: runner, health_checker: successful_health_checker)

      assert_difference -> { @app.runtime_instances.count }, 1 do
        result = agent.start_app(@app)

        assert result.success?
        assert_equal "container-123", result.payload.fetch(:container_id)
      end

      runtime_instance = @app.runtime_instances.order(:created_at).last
      run_command = runner.commands.third

      assert_equal "running", @app.reload.status
      assert_equal "running", runtime_instance.status
      assert_equal "container-123", runtime_instance.container_id
      assert_equal "172.17.0.2", runtime_instance.internal_host
      assert_equal 3000, runtime_instance.internal_port
      assert_equal "success", runtime_instance.health_check_result
      assert_equal 204, runtime_instance.health_check_status_code
      assert_equal "succeeded", @app.cold_start_metrics.last.status
      assert_equal 125, @app.cold_start_metrics.last.health_check_duration_ms
      assert_includes run_command, "--expose"
      assert_includes run_command, "3000"
      assert_includes run_command, "--cap-drop"
      assert_includes run_command, "ALL"
      assert_includes run_command, "--security-opt"
      assert_includes run_command, "no-new-privileges:true"
      assert_includes run_command, "--pids-limit"
      assert_includes run_command, "256"
      assert_includes run_command, "--network"
      assert_includes run_command, "hobby-apps"
      assert_includes run_command, "--network-alias"
      assert_includes run_command, "hobby-agent-app-d#{@deployment.id}-r#{runtime_instance.id}"
      assert_includes run_command, "--env"
      assert_includes run_command, "RAILS_ENV=production"
      assert_includes run_command, "DATABASE_URL=#{@database_resource.connection_url}"
      assert_includes run_command, "DATABASE_PASSWORD=#{@database_resource.password}"
      assert_includes run_command, "--volume"
      assert_includes run_command, "#{@app.volume.host_path}:/app/data"
      assert_includes run_command, "--memory=134217728"
      assert_includes run_command, "--cpus=0.5"
      assert_includes run_command, "#{LABEL_APP_ID}=#{@app.id}"
      assert_includes @app.app_events.pluck(:event_type), "runtime.start_succeeded"
      assert_includes @app.app_events.pluck(:event_type), "volume.mounted"
      assert_includes @app.app_events.pluck(:event_type), "health_check.started"
      assert_includes @app.app_events.pluck(:event_type), "health_check.succeeded"
    end

    test "creates the controlled app network before starting when it is missing" do
      runner = FakeRunner.new([
        FakeRunner.success,
        FakeRunner.failure("network not found"),
        FakeRunner.success("hobby-apps\n"),
        FakeRunner.success("container-123\n")
      ])
      agent = LocalDockerAgent.new(runner: runner, health_checker: successful_health_checker)

      result = agent.start_app(@app)

      assert result.success?
      assert_equal %w[docker network inspect hobby-apps], runner.commands.second
      assert_equal(
        [
          "docker", "network", "create", "--driver", "bridge", "--internal", "--label",
          "#{LABEL_PLATFORM}=true", "hobby-apps"
        ],
        runner.commands.third
      )
    end

    test "fails safely when the controlled app network cannot be prepared" do
      runner = FakeRunner.new([
        FakeRunner.success,
        FakeRunner.failure("network not found"),
        FakeRunner.failure("permission denied")
      ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.start_app(@app)

      assert_not result.success?
      assert_equal "network_unavailable", result.error.code
      assert_equal "wake_failed", @app.reload.status
      assert_equal "crashed", @app.runtime_instances.order(:created_at).last.status
    end

    test "marks wake failed when readiness check times out" do
      runner = FakeRunner.new([
        FakeRunner.success,
        FakeRunner.success,
        FakeRunner.success("container-123\n")
      ])
      health_checker = FakeHealthChecker.new(
        HealthChecker::Result.failure(
          kind: "http",
          target: { host: "172.17.0.2", port: 3000 },
          status_code: 503,
          duration_ms: 30_000,
          error_message: "Health check GET / did not return success before the 60 second startup timeout."
        )
      )
      agent = LocalDockerAgent.new(runner: runner, health_checker: health_checker)

      result = agent.start_app(@app)

      runtime_instance = @app.runtime_instances.order(:created_at).last
      assert_not result.success?
      assert_equal "health_check_failed", result.error.code
      assert_equal "wake_failed", @app.reload.status
      assert_equal "crashed", runtime_instance.status
      assert_equal "failure", runtime_instance.health_check_result
      assert_equal 503, runtime_instance.health_check_status_code
      assert_equal "failed", @app.cold_start_metrics.last.status
      assert_equal 30_000, @app.cold_start_metrics.last.health_check_duration_ms
      assert_match "Health check GET /", runtime_instance.failure_message
      assert_includes @app.app_events.pluck(:event_type), "health_check.failed"
    end

    test "normalizes start failures and records wake failure state" do
      runner = FakeRunner.new([
        FakeRunner.success,
        FakeRunner.success,
        FakeRunner.failure("port already allocated")
      ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.start_app(@app)

      assert_not result.success?
      assert_equal "start_failed", result.error.code
      assert_equal "wake_failed", @app.reload.status
      assert_equal "crashed", @app.runtime_instances.order(:created_at).last.status
      assert_equal "failed", @app.cold_start_metrics.last.status
      assert_includes @app.app_events.pluck(:event_type), "runtime.start_failed"
    end

    test "stops a running app container and records the stopped instance" do
      @app.manual_override_to!("running", reason: "test running container")
      runtime_instance = @app.runtime_instances.create!(status: "running", container_id: "container-123")
      runner = FakeRunner.new([ FakeRunner.success("container-123\n") ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.stop_app(@app)

      assert result.success?
      assert_equal "stopped", @app.reload.status
      assert_equal "stopped", runtime_instance.reload.status
      assert runtime_instance.stopped_at.present?
      assert_equal "docker", runner.commands.first.first
      assert_includes @app.app_events.pluck(:event_type), "runtime.stop_succeeded"
    end

    test "forces a container kill only after graceful stop fails" do
      @app.manual_override_to!("running", reason: "test running container")
      @app.runtime_instances.create!(status: "running", container_id: "container-123")
      runner = FakeRunner.new([
        FakeRunner.failure("timeout"),
        FakeRunner.success("container-123\n")
      ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.stop_app(@app)

      assert result.success?
      assert_equal true, result.payload.fetch(:forced)
      assert_equal %w[docker kill container-123], runner.commands.second
    end

    test "inspect syncs running containers back to app state" do
      @app.update!(status: "waking")
      runtime_instance = @app.runtime_instances.create!(status: "starting", container_id: "container-123")
      runner = FakeRunner.new([
        FakeRunner.success([ { State: { Running: true, ExitCode: 0 } } ].to_json)
      ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.inspect_app(@app)

      assert result.success?
      assert_equal "running", @app.reload.status
      assert_equal "running", runtime_instance.reload.status
      assert_nil runtime_instance.stopped_at
    end

    test "inspect records likely memory limit cause when docker reports oom killed" do
      @app.manual_override_to!("running", reason: "test running container")
      runtime_instance = @app.runtime_instances.create!(status: "running", container_id: "container-123")
      runner = FakeRunner.new([
        FakeRunner.success([ { State: { Running: false, ExitCode: 137, OOMKilled: true } } ].to_json),
        FakeRunner.success
      ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.inspect_app(@app)

      assert result.success?
      assert_equal "crashed", @app.reload.status
      assert_equal "crashed", runtime_instance.reload.status
      assert_equal 137, runtime_instance.exit_code
      assert_match "exceeding", runtime_instance.failure_message
      assert_equal "runtime.oom_killed", @app.app_events.order(:created_at).last.event_type
    end

    test "start rejects apps when host capacity is unavailable" do
      @node.update!(capacity_memory_bytes: 128.megabytes)
      @app.update!(memory_limit_bytes: 256.megabytes)
      runner = FakeRunner.new([])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.start_app(@app)

      assert_not result.success?
      assert_equal "capacity_unavailable", result.error.code
      assert_empty runner.commands
      assert_equal "runtime.capacity_unavailable", @app.app_events.order(:created_at).last.event_type
    end

    test "inspect captures runtime memory cpu and uptime snapshots" do
      @app.update!(status: "waking")
      runtime_instance = @app.runtime_instances.create!(
        status: "starting",
        container_id: "container-123",
        started_at: 2.minutes.ago
      )
      runner = FakeRunner.new([
        FakeRunner.success([ { State: { Running: true, ExitCode: 0 } } ].to_json),
        FakeRunner.success({ MemUsage: "12.5MiB / 1GiB", CPUPerc: "3.25%" }.to_json)
      ])
      agent = LocalDockerAgent.new(runner: runner)

      assert_difference -> { runtime_instance.runtime_metric_snapshots.count }, 1 do
        result = agent.inspect_app(@app)

        assert result.success?
      end

      snapshot = runtime_instance.runtime_metric_snapshots.last
      assert_equal 13_107_200, snapshot.memory_usage_bytes
      assert_equal BigDecimal("3.25"), snapshot.cpu_usage_percent
      assert snapshot.uptime_seconds >= 120
    end

    test "inspect marks missing containers so apps are not falsely running" do
      @app.manual_override_to!("running", reason: "test running container")
      runtime_instance = @app.runtime_instances.create!(status: "running", container_id: "missing-123")
      runner = FakeRunner.new([ FakeRunner.failure("No such object") ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.inspect_app(@app)

      assert_not result.success?
      assert_equal "container_missing", result.error.code
      assert_equal "crashed", @app.reload.status
      assert_equal "missing", runtime_instance.reload.status
      assert_includes @app.app_events.pluck(:event_type), "runtime.inspect_missing"
    end

    test "gets container logs through the normalized runtime interface" do
      @app.runtime_instances.create!(status: "running", container_id: "container-123")
      runner = FakeRunner.new([
        DockerRunner::CommandResult.new(
          "2026-05-19T12:00:00.000000000Z booted\n",
          "2026-05-19T12:00:01.000000000Z warned\n",
          0
        )
      ])
      agent = LocalDockerAgent.new(runner: runner)

      assert_difference -> { @app.app_logs.count }, 2 do
        result = agent.get_logs(@app, lines: 50)

        assert result.success?
        assert_includes result.payload.fetch(:logs), "booted"
      end
      assert_equal %w[docker logs --timestamps --tail 50 container-123], runner.commands.first
      assert_equal %w[stdout stderr], @app.app_logs.order(:logged_at).pluck(:stream)
    end

    test "cleanup removes only old stopped platform containers and records an event" do
      platform_runtime = @app.runtime_instances.create!(
        status: "stopped",
        container_id: "platform-123",
        stopped_at: 2.days.ago
      )
      other_runtime = @app.runtime_instances.create!(
        status: "stopped",
        container_id: "other-123",
        stopped_at: 2.days.ago
      )
      runner = FakeRunner.new([
        FakeRunner.success("true\n"),
        FakeRunner.success("platform-123\n"),
        FakeRunner.success("false\n")
      ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.cleanup_stopped_containers

      assert result.success?
      assert_equal [ "platform-123" ], result.payload.fetch(:removed_containers)
      assert_includes @app.app_events.pluck(:event_type), "runtime.cleanup_removed"
      assert_equal platform_runtime.id, @app.app_events.order(:created_at).last.metadata.fetch("runtime_instance_id")
      assert_equal "other-123", other_runtime.reload.container_id
    end

    test "lists platform containers with labels for startup reconciliation" do
      runner = FakeRunner.new([
        FakeRunner.success(
          {
            ID: "container-123",
            Names: "hobby-agent-app",
            State: "running",
            Status: "Up 2 minutes",
            Labels: "#{LABEL_PLATFORM}=true,#{LABEL_APP_ID}=#{@app.id}"
          }.to_json + "\n"
        )
      ])
      agent = LocalDockerAgent.new(runner: runner)

      result = agent.list_platform_containers

      assert result.success?
      assert_equal(
        [ "docker", "ps", "--all", "--filter", "label=hobby.platform=true", "--format", "{{ json . }}" ],
        runner.commands.first
      )
      container = result.payload.fetch(:containers).first
      assert_equal "container-123", container.fetch(:container_id)
      assert_equal "running", container.fetch(:state)
      assert_equal @app.id.to_s, container.fetch(:labels).fetch(LABEL_APP_ID)
    end

    test "checks whether the Docker runtime is available" do
      runner = FakeRunner.new([ FakeRunner.success("\"24.0.0\"\n") ])
      agent = LocalDockerAgent.new(runner: runner)

      assert agent.platform_available?
      assert_equal %w[docker info --format {{json .ServerVersion}}], runner.commands.first
    end

    test "reports Docker unavailable when the docker executable is missing" do
      runner = Class.new do
        def call(_command)
          raise Errno::ENOENT, "No such file or directory - docker"
        end
      end.new
      agent = LocalDockerAgent.new(runner: runner)

      assert_not agent.platform_available?
    end

    private

    def successful_health_checker
      FakeHealthChecker.new(
        HealthChecker::Result.success(
          kind: "http",
          target: { host: "172.17.0.2", port: 3000 },
          status_code: 204,
          duration_ms: 125
        )
      )
    end
  end
end

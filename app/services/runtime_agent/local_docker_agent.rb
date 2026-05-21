require "json"

module RuntimeAgent
  class LocalDockerAgent
    PLATFORM_LABEL_VALUE = "true".freeze
    DEFAULT_APP_NETWORK = "hobby-apps".freeze
    DEFAULT_STOP_TIMEOUT_SECONDS = 10
    DEFAULT_LOG_LINES = 200

    def initialize(runner: DockerRunner.new, health_checker: nil)
      @runner = runner
      @health_checker = health_checker || HealthChecker.new(runner: runner)
    end

    def start_app(app)
      deployment = app.current_deployment
      return failure(:missing_deployment, "App has no current deployment") unless deployment
      capacity = RuntimeCapacityGuard.new(node: app.node).check(app)
      return capacity_failure(app, capacity) unless capacity.success?

      wake_started_at = Time.current
      wake_started_monotonic = monotonic_time
      runtime_instance = app.runtime_instances.create!(status: "starting")
      app.record_runtime_environment_prepared!
      app.manual_override_to!("waking", reason: "runtime agent start")

      verify_image!(deployment.image_reference)
      ensure_app_network!
      container_name = container_name_for(app, deployment, runtime_instance)
      command = start_command(app, deployment, runtime_instance, container_name)
      container_start_started_at = monotonic_time
      result = run(command)
      container_start_duration_ms = elapsed_ms(container_start_started_at)

      unless result.success?
        mark_start_failed(
          app,
          runtime_instance,
          result,
          wake_started_at: wake_started_at,
          total_wake_duration_ms: elapsed_ms(wake_started_monotonic),
          container_start_duration_ms: container_start_duration_ms
        )
        return command_failure(:start_failed, "Container start failed", command, result)
      end

      container_id = result.stdout.strip
      runtime_instance.update!(
        container_id: container_id,
        started_at: Time.current,
        last_seen_at: Time.current
      )
      app.record_event!(
        "runtime.start_succeeded",
        "Container start requested for #{app.name}",
        metadata: start_metadata(app, runtime_instance, container_name, deployment)
      )

      readiness = wait_for_readiness!(
        app,
        deployment,
        runtime_instance,
        wake_started_at: wake_started_at,
        wake_started_monotonic: wake_started_monotonic,
        container_start_duration_ms: container_start_duration_ms
      )
      return readiness unless readiness.success?

      Result.success(
        command: "start_app",
        runtime_instance_id: runtime_instance.id,
        container_id: container_id,
        status: runtime_instance.status
      )
    rescue RuntimeAgent::Failure => failure
      if runtime_instance
        mark_start_failed(
          app,
          runtime_instance,
          failure.error,
          wake_started_at: wake_started_at,
          total_wake_duration_ms: elapsed_ms(wake_started_monotonic),
          container_start_duration_ms: nil
        )
      end
      Result.failure(failure.error)
    end

    def stop_app(app, timeout_seconds: DEFAULT_STOP_TIMEOUT_SECONDS)
      runtime_instance = latest_active_container_runtime(app)
      return failure(:missing_runtime, "App has no container-backed runtime instance") unless runtime_instance

      app.manual_override_to!("stopping", reason: "runtime agent stop")
      stop_result = run(%w[docker stop] + [ "--time", timeout_seconds.to_s, runtime_instance.container_id ])
      kill_result = nil

      unless stop_result.success?
        kill_result = run(%w[docker kill] + [ runtime_instance.container_id ])
        return command_failure(:stop_failed, "Container stop failed", %w[docker stop], stop_result) unless kill_result.success?
      end

      runtime_instance.update!(status: "stopped", stopped_at: Time.current, last_seen_at: Time.current)
      collect_runtime_logs(app, runtime_instance)
      app.manual_override_to!("stopped", reason: "runtime agent stop completed")
      app.record_event!(
        "runtime.stop_succeeded",
        "Container stopped for #{app.name}",
        metadata: {
          runtime_instance_id: runtime_instance.id,
          container_id: runtime_instance.container_id,
          forced: kill_result.present?
        }
      )

      Result.success(
        command: "stop_app",
        runtime_instance_id: runtime_instance.id,
        container_id: runtime_instance.container_id,
        forced: kill_result.present?,
        status: runtime_instance.status
      )
    end

    def inspect_app(app)
      runtime_instance = latest_container_runtime(app)
      return failure(:missing_runtime, "App has no container-backed runtime instance") unless runtime_instance

      result = run(%w[docker inspect] + [ runtime_instance.container_id ])

      unless result.success?
        runtime_instance.update!(status: "missing", last_seen_at: Time.current)
        app.manual_override_to!("crashed", reason: "runtime agent inspect missing container")
        app.record_event!(
          "runtime.inspect_missing",
          "Container is missing for #{app.name}",
          metadata: { runtime_instance_id: runtime_instance.id, container_id: runtime_instance.container_id }
        )
        return command_failure(:container_missing, "Container could not be inspected", %w[docker inspect], result)
      end

      inspection = JSON.parse(result.stdout).first
      state = inspection.fetch("State", {})
      sync_inspection!(app, runtime_instance, state)
      capture_runtime_metrics(app, runtime_instance, state)
      collect_runtime_logs(app, runtime_instance)

      Result.success(
        command: "inspect_app",
        runtime_instance_id: runtime_instance.id,
        container_id: runtime_instance.container_id,
        status: runtime_instance.status,
        app_status: app.status,
        exit_code: runtime_instance.exit_code
      )
    rescue JSON::ParserError => error
      failure(:inspect_parse_failed, "Docker inspect returned invalid JSON", details: { error: error.message })
    end

    def get_logs(app, lines: DEFAULT_LOG_LINES)
      runtime_instance = latest_container_runtime(app)
      return failure(:missing_runtime, "App has no container-backed runtime instance") unless runtime_instance

      command = %w[docker logs] + [ "--timestamps", "--tail", lines.to_s, runtime_instance.container_id ]
      result = run(command)
      return command_failure(:logs_failed, "Container logs could not be read", command, result) unless result.success?

      AppLog.ingest_docker_output!(
        app: app,
        runtime_instance: runtime_instance,
        stdout: result.stdout,
        stderr: result.stderr
      )

      Result.success(
        command: "get_logs",
        runtime_instance_id: runtime_instance.id,
        container_id: runtime_instance.container_id,
        logs: [ result.stdout, result.stderr ].compact_blank.join
      )
    end

    def container_status(app)
      inspect_result = inspect_app(app)
      return inspect_result unless inspect_result.success?

      Result.success(inspect_result.payload.slice(:runtime_instance_id, :container_id, :status, :app_status, :exit_code))
    end

    def cleanup_stopped_containers(older_than: 1.day.ago)
      removed = []

      RuntimeInstance.where(status: %w[stopped crashed missing])
                     .where.not(container_id: nil)
                     .where(stopped_at: ...older_than)
                     .find_each do |runtime_instance|
        next unless platform_container?(runtime_instance.container_id)

        remove_result = run(%w[docker rm] + [ runtime_instance.container_id ])
        next unless remove_result.success?

        runtime_instance.app.record_event!(
          "runtime.cleanup_removed",
          "Removed old runtime container",
          metadata: {
            runtime_instance_id: runtime_instance.id,
            container_id: runtime_instance.container_id
          }
        )
        removed << runtime_instance.container_id
      end

      Result.success(command: "cleanup_stopped_containers", removed_containers: removed)
    end

    private

    attr_reader :runner, :health_checker

    def verify_image!(image_reference)
      inspect_result = run(%w[docker image inspect] + [ image_reference ])
      return if inspect_result.success?

      pull_result = run(%w[docker pull] + [ image_reference ])
      return if pull_result.success?

      raise Failure.new(
        normalized_error(:image_unavailable, "Image is not available locally and could not be pulled",
                         %w[docker pull] + [ image_reference ], pull_result)
      )
    end

    def start_command(app, deployment, runtime_instance, container_name)
      command = %w[docker run --detach --name] + [ container_name ]
      command += label_args(app, deployment, runtime_instance)
      command += isolation_args
      command += network_args(container_name)
      command += env_args(app.runtime_environment)
      command += volume_args(app)
      command += [ "--expose", deployment.port.to_s ]
      command << "--memory=#{app.memory_limit_bytes}" if app.memory_limit_bytes.present?
      command << "--cpus=#{app.cpu_limit}" if app.cpu_limit.present?
      command << deployment.image_reference
      command
    end

    def ensure_app_network!
      inspect_result = run(%w[docker network inspect] + [ app_network_name ])
      return if inspect_result.success?

      create_result = run(
        %w[docker network create --driver bridge --internal --label] +
          [ "#{LABEL_PLATFORM}=#{PLATFORM_LABEL_VALUE}", app_network_name ]
      )
      raise Failure.new(
        normalized_error(:network_unavailable, "App network could not be created", %w[docker network create], create_result)
      ) unless create_result.success?
    end

    def isolation_args
      [
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges:true",
        "--pids-limit", "256"
      ]
    end

    def network_args(container_name)
      [
        "--network", app_network_name,
        "--network-alias", container_name
      ]
    end

    def app_network_name
      ENV["PLATFORM_APP_NETWORK"].presence || DEFAULT_APP_NETWORK
    end

    def label_args(app, deployment, runtime_instance)
      [
        "--label", "#{LABEL_PLATFORM}=#{PLATFORM_LABEL_VALUE}",
        "--label", "#{LABEL_APP_ID}=#{app.id}",
        "--label", "#{LABEL_DEPLOYMENT_ID}=#{deployment.id}",
        "--label", "#{LABEL_RUNTIME_INSTANCE_ID}=#{runtime_instance.id}"
      ]
    end

    def env_args(environment)
      environment.flat_map { |key, value| [ "--env", "#{key}=#{value}" ] }
    end

    def volume_args(app)
      volume = app.active_volume
      return [] unless volume

      volume.ensure_host_directory!
      app.record_event!(
        "volume.mounted",
        "Persistent volume mounted for #{app.name}",
        metadata: volume.metadata
      )
      [ "--volume", volume.runtime_mount ]
    end

    def sync_inspection!(app, runtime_instance, state)
      exit_code = state["ExitCode"]
      running = state["Running"]
      status = running ? "running" : stopped_status_for(exit_code)
      oom_killed = state["OOMKilled"]
      app_status = running ? "running" : stopped_app_status_for(exit_code, oom_killed: oom_killed)
      failure_message = oom_killed ? oom_failure_message(app) : runtime_instance.failure_message

      runtime_instance.update!(
        status: status,
        exit_code: exit_code,
        failure_message: failure_message,
        last_seen_at: Time.current,
        stopped_at: running ? nil : Time.current
      )
      app.manual_override_to!(app_status, reason: "runtime agent inspect sync")
      record_oom_event(app, runtime_instance) if oom_killed
    end

    def stopped_status_for(exit_code)
      exit_code.to_i.zero? ? "stopped" : "crashed"
    end

    def stopped_app_status_for(exit_code, oom_killed: false)
      return "crashed" if oom_killed

      exit_code.to_i.zero? ? "stopped" : "crashed"
    end

    def latest_container_runtime(app)
      app.runtime_instances.where.not(container_id: nil).order(created_at: :desc).first
    end

    def latest_active_container_runtime(app)
      app.runtime_instances.where(status: %w[starting running])
         .where.not(container_id: nil)
         .order(created_at: :desc)
         .first
    end

    def container_name_for(app, deployment, runtime_instance)
      "hobby-#{app.slug}-d#{deployment.id}-r#{runtime_instance.id}"
    end

    def platform_container?(container_id)
      result = run([
        "docker", "inspect", "--format",
        "{{ index .Config.Labels \"#{LABEL_PLATFORM}\" }}",
        container_id
      ])
      result.success? && result.stdout.strip == PLATFORM_LABEL_VALUE
    end

    def wait_for_readiness!(app, deployment, runtime_instance, wake_started_at:, wake_started_monotonic:,
                            container_start_duration_ms:)
      app.record_event!(
        "health_check.started",
        "Readiness check started for #{app.name}",
        metadata: health_check_metadata(runtime_instance, deployment)
      )

      result = health_checker.wait_until_ready(
        deployment: deployment,
        runtime_instance: runtime_instance,
        timeout_seconds: app.startup_timeout_seconds
      )

      if result.success?
        mark_health_check_succeeded(
          app,
          runtime_instance,
          result,
          wake_started_at: wake_started_at,
          total_wake_duration_ms: elapsed_ms(wake_started_monotonic),
          container_start_duration_ms: container_start_duration_ms
        )
        Result.success(command: "health_check", runtime_instance_id: runtime_instance.id)
      else
        mark_health_check_failed(
          app,
          runtime_instance,
          result,
          wake_started_at: wake_started_at,
          total_wake_duration_ms: elapsed_ms(wake_started_monotonic),
          container_start_duration_ms: container_start_duration_ms
        )
        failure(:health_check_failed, result.error_message, details: health_check_result_metadata(result))
      end
    end

    def run(command)
      runner.call(command)
    end

    def mark_start_failed(app, runtime_instance, failure, wake_started_at:, total_wake_duration_ms:,
                          container_start_duration_ms:)
      message = failure.respond_to?(:message) ? failure.message : failure.stderr.presence || "Container start failed"
      runtime_instance.update!(status: "crashed", failure_message: message, stopped_at: Time.current)
      record_cold_start_metric!(
        app,
        runtime_instance,
        status: "failed",
        wake_started_at: wake_started_at,
        total_wake_duration_ms: total_wake_duration_ms,
        container_start_duration_ms: container_start_duration_ms,
        failure_message: message
      )
      app.manual_override_to!("wake_failed", reason: "runtime agent start failed")
      app.record_event!(
        "runtime.start_failed",
        "Container start failed for #{app.name}",
        metadata: { runtime_instance_id: runtime_instance.id, error: normalized_failure_payload(failure) }
      )
    end

    def mark_health_check_succeeded(app, runtime_instance, result, wake_started_at:, total_wake_duration_ms:,
                                    container_start_duration_ms:)
      runtime_instance.update!(
        status: "running",
        last_seen_at: Time.current,
        internal_host: result.target.fetch(:host),
        internal_port: result.target.fetch(:port),
        health_check_result: "success",
        health_check_status_code: result.status_code,
        health_check_checked_at: Time.current
      )
      record_cold_start_metric!(
        app,
        runtime_instance,
        status: "succeeded",
        wake_started_at: wake_started_at,
        total_wake_duration_ms: total_wake_duration_ms,
        container_start_duration_ms: container_start_duration_ms,
        health_check_duration_ms: result.duration_ms
      )
      app.manual_override_to!("running", reason: "runtime health check passed")
      app.record_event!(
        "health_check.succeeded",
        "Readiness check passed for #{app.name}",
        metadata: health_check_result_metadata(result).merge(runtime_instance_id: runtime_instance.id)
      )
    end

    def mark_health_check_failed(app, runtime_instance, result, wake_started_at:, total_wake_duration_ms:,
                                 container_start_duration_ms:)
      runtime_instance.update!(
        status: "crashed",
        failure_message: result.error_message,
        stopped_at: Time.current,
        last_seen_at: Time.current,
        health_check_result: "failure",
        health_check_status_code: result.status_code,
        health_check_checked_at: Time.current
      )
      record_cold_start_metric!(
        app,
        runtime_instance,
        status: "failed",
        wake_started_at: wake_started_at,
        total_wake_duration_ms: total_wake_duration_ms,
        container_start_duration_ms: container_start_duration_ms,
        health_check_duration_ms: result.duration_ms,
        failure_message: result.error_message
      )
      collect_runtime_logs(app, runtime_instance)
      app.manual_override_to!("wake_failed", reason: "runtime health check failed")
      app.record_event!(
        "health_check.failed",
        "Readiness check failed for #{app.name}",
        metadata: health_check_result_metadata(result).merge(runtime_instance_id: runtime_instance.id)
      )
    end

    def normalized_failure_payload(failure)
      return failure.to_h if failure.respond_to?(:to_h)

      {
        exit_status: failure.exit_status,
        stderr: failure.stderr
      }
    end

    def start_metadata(app, runtime_instance, container_name, deployment)
      {
        runtime_instance_id: runtime_instance.id,
        container_id: runtime_instance.container_id,
        container_name: container_name,
        deployment_id: deployment.id,
        image_reference: deployment.image_reference,
        port: deployment.port,
        health_check_kind: deployment.health_check_kind,
        health_check_path: deployment.health_check_path,
        memory_limit_bytes: app.memory_limit_bytes,
        cpu_limit: app.cpu_limit,
        volume_id: app.active_volume&.id,
        volume_mount_path: app.active_volume&.mount_path
      }
    end

    def health_check_metadata(runtime_instance, deployment)
      {
        runtime_instance_id: runtime_instance.id,
        container_id: runtime_instance.container_id,
        deployment_id: deployment.id,
        kind: deployment.health_check_kind,
        path: deployment.health_check_path,
        port: deployment.port
      }
    end

    def health_check_result_metadata(result)
      {
        kind: result.kind,
        target: result.target,
        status_code: result.status_code,
        duration_ms: result.duration_ms,
        error_message: result.error_message
      }.compact
    end

    def collect_runtime_logs(app, runtime_instance)
      return if runtime_instance&.container_id.blank?

      get_logs(app)
    end

    def capacity_failure(app, capacity)
      app.record_event!(
        "runtime.capacity_unavailable",
        capacity.error,
        metadata: capacity.details
      )
      Result.failure(Error.new("capacity_unavailable", capacity.error, nil, nil, nil, capacity.details))
    end

    def oom_failure_message(app)
      if app.memory_limit_bytes.present?
        "Container was killed after exceeding the #{app.memory_limit_bytes} byte memory limit."
      else
        "Container was killed after exceeding its memory limit."
      end
    end

    def record_oom_event(app, runtime_instance)
      app.record_event!(
        "runtime.oom_killed",
        "Container was killed after exceeding its memory limit.",
        metadata: {
          runtime_instance_id: runtime_instance.id,
          container_id: runtime_instance.container_id,
          memory_limit_bytes: app.memory_limit_bytes,
          exit_code: runtime_instance.exit_code
        }
      )
    end

    def capture_runtime_metrics(app, runtime_instance, state)
      return unless state["Running"]

      result = run([ "docker", "stats", "--no-stream", "--format", "{{ json . }}", runtime_instance.container_id ])
      return unless result.success?

      payload = JSON.parse(result.stdout)
      runtime_instance.runtime_metric_snapshots.create!(
        app: app,
        captured_at: Time.current,
        memory_usage_bytes: parse_memory_usage(payload["MemUsage"]),
        cpu_usage_percent: parse_percentage(payload["CPUPerc"]),
        uptime_seconds: runtime_uptime_seconds(runtime_instance)
      )
    rescue JSON::ParserError, ActiveRecord::RecordInvalid
      app.record_event!(
        "runtime.metrics_failed",
        "Runtime metrics could not be captured for #{app.name}",
        metadata: { runtime_instance_id: runtime_instance.id }
      )
    end

    def record_cold_start_metric!(app, runtime_instance, status:, wake_started_at:, total_wake_duration_ms:,
                                  container_start_duration_ms: nil, health_check_duration_ms: nil,
                                  failure_message: nil)
      app.cold_start_metrics.create!(
        runtime_instance: runtime_instance,
        started_at: wake_started_at,
        finished_at: Time.current,
        status: status,
        container_start_duration_ms: container_start_duration_ms,
        health_check_duration_ms: health_check_duration_ms,
        total_wake_duration_ms: total_wake_duration_ms,
        failure_message: failure_message
      )
    end

    def parse_percentage(value)
      value.to_s.delete("%").presence&.to_d
    end

    def parse_memory_usage(value)
      used_memory = value.to_s.split("/").first.to_s.strip
      number, unit = used_memory.match(/\A([\d.]+)\s*([A-Za-z]+)?\z/)&.captures
      return if number.blank?

      (number.to_d * memory_unit_multiplier(unit)).round
    end

    def memory_unit_multiplier(unit)
      {
        "b" => 1,
        "kb" => 1_000,
        "mb" => 1_000_000,
        "gb" => 1_000_000_000,
        "kib" => 1024,
        "mib" => 1024**2,
        "gib" => 1024**3
      }.fetch(unit.to_s.downcase, 1)
    end

    def runtime_uptime_seconds(runtime_instance)
      return unless runtime_instance.started_at

      (Time.current - runtime_instance.started_at).round
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round
    end

    def command_failure(code, message, command, result)
      Result.failure(normalized_error(code, message, command, result))
    end

    def failure(code, message, command: nil, exit_status: nil, stderr: nil, details: {})
      Result.failure(Error.new(code.to_s, message, command, exit_status, stderr, details))
    end

    def normalized_error(code, message, command, result)
      Error.new(code.to_s, message, command, result.exit_status, result.stderr.presence, {})
    end
  end
end

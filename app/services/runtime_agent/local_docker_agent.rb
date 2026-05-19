require "json"

module RuntimeAgent
  class LocalDockerAgent
    PLATFORM_LABEL_VALUE = "true".freeze
    DEFAULT_STOP_TIMEOUT_SECONDS = 10
    DEFAULT_LOG_LINES = 200

    def initialize(runner: DockerRunner.new, health_checker: nil)
      @runner = runner
      @health_checker = health_checker || HealthChecker.new(runner: runner)
    end

    def start_app(app)
      deployment = app.current_deployment
      return failure(:missing_deployment, "App has no current deployment") unless deployment

      runtime_instance = app.runtime_instances.create!(status: "starting")
      app.record_runtime_environment_prepared!
      app.manual_override_to!("waking", reason: "runtime agent start")

      verify_image!(deployment.image_reference)
      container_name = container_name_for(app, deployment, runtime_instance)
      command = start_command(app, deployment, runtime_instance, container_name)
      result = run(command)

      unless result.success?
        mark_start_failed(app, runtime_instance, result)
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
        metadata: start_metadata(runtime_instance, container_name, deployment)
      )

      readiness = wait_for_readiness!(app, deployment, runtime_instance)
      return readiness unless readiness.success?

      Result.success(
        command: "start_app",
        runtime_instance_id: runtime_instance.id,
        container_id: container_id,
        status: runtime_instance.status
      )
    rescue RuntimeAgent::Failure => failure
      mark_start_failed(app, runtime_instance, failure.error) if runtime_instance
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

      command = %w[docker logs] + [ "--tail", lines.to_s, runtime_instance.container_id ]
      result = run(command)
      return command_failure(:logs_failed, "Container logs could not be read", command, result) unless result.success?

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
      command += env_args(app.runtime_environment)
      command += [ "--expose", deployment.port.to_s ]
      command << "--memory=#{app.memory_limit_bytes}" if app.memory_limit_bytes.present?
      command << "--cpus=#{app.cpu_limit}" if app.cpu_limit.present?
      command << deployment.image_reference
      command
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

    def sync_inspection!(app, runtime_instance, state)
      exit_code = state["ExitCode"]
      running = state["Running"]
      status = running ? "running" : stopped_status_for(exit_code)
      app_status = running ? "running" : stopped_app_status_for(exit_code)

      runtime_instance.update!(
        status: status,
        exit_code: exit_code,
        last_seen_at: Time.current,
        stopped_at: running ? nil : Time.current
      )
      app.manual_override_to!(app_status, reason: "runtime agent inspect sync")
    end

    def stopped_status_for(exit_code)
      exit_code.to_i.zero? ? "stopped" : "crashed"
    end

    def stopped_app_status_for(exit_code)
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

    def wait_for_readiness!(app, deployment, runtime_instance)
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
        mark_health_check_succeeded(app, runtime_instance, result)
        Result.success(command: "health_check", runtime_instance_id: runtime_instance.id)
      else
        mark_health_check_failed(app, runtime_instance, result)
        failure(:health_check_failed, result.error_message, details: health_check_result_metadata(result))
      end
    end

    def run(command)
      runner.call(command)
    end

    def mark_start_failed(app, runtime_instance, failure)
      message = failure.respond_to?(:message) ? failure.message : failure.stderr.presence || "Container start failed"
      runtime_instance.update!(status: "crashed", failure_message: message, stopped_at: Time.current)
      app.manual_override_to!("wake_failed", reason: "runtime agent start failed")
      app.record_event!(
        "runtime.start_failed",
        "Container start failed for #{app.name}",
        metadata: { runtime_instance_id: runtime_instance.id, error: normalized_failure_payload(failure) }
      )
    end

    def mark_health_check_succeeded(app, runtime_instance, result)
      runtime_instance.update!(
        status: "running",
        last_seen_at: Time.current,
        health_check_result: "success",
        health_check_status_code: result.status_code,
        health_check_checked_at: Time.current
      )
      app.manual_override_to!("running", reason: "runtime health check passed")
      app.record_event!(
        "health_check.succeeded",
        "Readiness check passed for #{app.name}",
        metadata: health_check_result_metadata(result).merge(runtime_instance_id: runtime_instance.id)
      )
    end

    def mark_health_check_failed(app, runtime_instance, result)
      runtime_instance.update!(
        status: "crashed",
        failure_message: result.error_message,
        stopped_at: Time.current,
        last_seen_at: Time.current,
        health_check_result: "failure",
        health_check_status_code: result.status_code,
        health_check_checked_at: Time.current
      )
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

    def start_metadata(runtime_instance, container_name, deployment)
      {
        runtime_instance_id: runtime_instance.id,
        container_id: runtime_instance.container_id,
        container_name: container_name,
        deployment_id: deployment.id,
        image_reference: deployment.image_reference,
        port: deployment.port,
        health_check_kind: deployment.health_check_kind,
        health_check_path: deployment.health_check_path
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

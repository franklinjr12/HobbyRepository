require "json"
require "net/http"
require "socket"
require "timeout"
require "uri"

module RuntimeAgent
  class HealthChecker
    Result = Data.define(:success, :kind, :target, :status_code, :duration_ms, :error_message) do
      alias success? success

      def self.success(kind:, target:, status_code:, duration_ms:)
        new(true, kind, target, status_code, duration_ms, nil)
      end

      def self.failure(kind:, target:, status_code:, duration_ms:, error_message:)
        new(false, kind, target, status_code, duration_ms, error_message)
      end
    end

    def initialize(runner:, interval_seconds: 0.5)
      @runner = runner
      @interval_seconds = interval_seconds
    end

    def wait_until_ready(deployment:, runtime_instance:, timeout_seconds:)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started_at + timeout_seconds
      target = target_for(runtime_instance.container_id, deployment.port)
      last_status_code = nil
      last_error = nil

      loop do
        last_status_code, last_error = probe(deployment, target)
        duration_ms = elapsed_ms(started_at)
        return success_result(deployment, target, last_status_code, duration_ms) if ready?(deployment, last_status_code, last_error)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep @interval_seconds
      end

      Result.failure(
        kind: deployment.health_check_kind,
        target: target,
        status_code: last_status_code,
        duration_ms: elapsed_ms(started_at),
        error_message: failure_message(deployment, last_status_code, last_error, timeout_seconds)
      )
    rescue RuntimeError => error
      Result.failure(
        kind: deployment.health_check_kind,
        target: { port: deployment.port },
        status_code: nil,
        duration_ms: elapsed_ms(started_at),
        error_message: error.message
      )
    end

    private

    attr_reader :runner

    def probe(deployment, target)
      if deployment.health_check_kind == "port"
        probe_port(target)
      else
        probe_http(target, deployment.health_check_path)
      end
    rescue StandardError => error
      [ nil, error.message ]
    end

    def probe_http(target, path)
      uri = URI::HTTP.build(host: target.fetch(:host), port: target.fetch(:port), path: path)
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
        http.get(uri.request_uri)
      end

      [ response.code.to_i, nil ]
    end

    def probe_port(target)
      TCPSocket.open(target.fetch(:host), target.fetch(:port)) { |socket| socket.close }
      [ nil, nil ]
    end

    def ready?(deployment, status_code, error)
      return error.blank? if deployment.health_check_kind == "port"

      error.blank? && status_code.between?(200, 399)
    end

    def success_result(deployment, target, status_code, duration_ms)
      Result.success(
        kind: deployment.health_check_kind,
        target: target,
        status_code: status_code,
        duration_ms: duration_ms
      )
    end

    def failure_message(deployment, status_code, error, timeout_seconds)
      return "Port #{deployment.port} did not accept connections before the #{timeout_seconds} second startup timeout." if deployment.health_check_kind == "port"

      if status_code
        "Health check GET #{deployment.health_check_path} returned HTTP #{status_code} before timing out."
      else
        "Health check GET #{deployment.health_check_path} did not return success before the #{timeout_seconds} second startup timeout. #{error}".strip
      end
    end

    def target_for(container_id, port)
      {
        host: container_ip_for(container_id),
        port: port
      }
    end

    def container_ip_for(container_id)
      result = runner.call(%w[docker inspect] + [ container_id ])
      raise "Container network address could not be inspected" unless result.success?

      inspection = JSON.parse(result.stdout).first
      network_settings = inspection.fetch("NetworkSettings", {})
      direct_ip = network_settings["IPAddress"].presence
      return direct_ip if direct_ip

      network_settings.fetch("Networks", {}).each_value do |network|
        ip_address = network["IPAddress"].presence
        return ip_address if ip_address
      end

      raise "Container network address was not available"
    rescue JSON::ParserError => error
      raise "Container inspect returned invalid JSON: #{error.message}"
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end
  end
end

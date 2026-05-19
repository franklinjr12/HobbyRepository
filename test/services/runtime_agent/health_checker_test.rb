require "test_helper"

module RuntimeAgent
  class HealthCheckerTest < ActiveSupport::TestCase
    class FakeRunner
      def initialize(ip_address: "127.0.0.1")
        @ip_address = ip_address
      end

      def call(_command)
        DockerRunner::CommandResult.new(
          [ { NetworkSettings: { IPAddress: @ip_address } } ].to_json,
          "",
          0
        )
      end
    end

    setup do
      node = Node.create!(name: "Local", hostname: "local.test", local: true)
      owner = User.create!(email: "health@example.com", password: "password123")
      @app = App.create!(
        name: "Health App",
        slug: "health-app",
        owner: owner,
        node: node,
        image_reference: "example/health:latest",
        internal_port: 3000,
        startup_timeout_seconds: 1
      )
      @runtime_instance = @app.runtime_instances.create!(status: "starting", container_id: "container-123")
    end

    test "http health check succeeds on successful status" do
      with_http_server("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n") do |port|
        deployment = @app.deployments.create!(
          image_reference: "example/health:latest",
          port: port,
          health_check_kind: "http",
          health_check_path: "/ready",
          current: true
        )
        checker = HealthChecker.new(runner: FakeRunner.new, interval_seconds: 0)

        result = checker.wait_until_ready(
          deployment: deployment,
          runtime_instance: @runtime_instance,
          timeout_seconds: 1
        )

        assert result.success?
        assert_equal "http", result.kind
        assert_equal 204, result.status_code
      end
    end

    test "port health check succeeds when tcp port accepts connections" do
      with_tcp_server do |port|
        deployment = @app.deployments.create!(
          image_reference: "example/health:latest",
          port: port,
          health_check_kind: "port",
          health_check_path: nil,
          current: true
        )
        checker = HealthChecker.new(runner: FakeRunner.new, interval_seconds: 0)

        result = checker.wait_until_ready(
          deployment: deployment,
          runtime_instance: @runtime_instance,
          timeout_seconds: 1
        )

        assert result.success?
        assert_equal "port", result.kind
        assert_nil result.status_code
      end
    end

    test "http health check reports timeout and status code" do
      with_http_server("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n") do |port|
        deployment = @app.deployments.create!(
          image_reference: "example/health:latest",
          port: port,
          health_check_kind: "http",
          health_check_path: "/ready",
          current: true
        )
        checker = HealthChecker.new(runner: FakeRunner.new, interval_seconds: 0)

        result = checker.wait_until_ready(
          deployment: deployment,
          runtime_instance: @runtime_instance,
          timeout_seconds: 0
        )

        assert_not result.success?
        assert_equal 503, result.status_code
        assert_match "HTTP 503", result.error_message
      end
    end

    private

    def with_http_server(response)
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          socket = server.accept
          socket.readpartial(1024)
          socket.write(response)
          socket.close
        rescue IOError
          break
        end
      end

      yield server.addr[1]
    ensure
      server&.close
      thread&.kill
    end

    def with_tcp_server
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          socket = server.accept
          socket.close
        rescue IOError
          break
        end
      end

      yield server.addr[1]
    ensure
      server&.close
      thread&.kill
    end
  end
end

require "test_helper"
require "net/http"

class LocalGatewayControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  FakeResponse = Data.define(:code, :body, :headers) do
    def each_header(&block)
      headers.each(&block)
    end
  end

  class FakeHttp
    attr_reader :upstream_request

    def initialize(response)
      @response = response
    end

    def request(request)
      @upstream_request = request
      @response
    end
  end

  setup do
    @node = Node.create!(name: "Local", hostname: "gateway-local.test", local: true)
    @owner = User.create!(email: "local-gateway@example.com", password: "password123")
    @hosted_app = @owner.apps.create!(name: "Gateway Local", node: @node, status: "running")
    @runtime_instance = @hosted_app.runtime_instances.create!(
      status: "running",
      container_id: "container-123",
      internal_host: "172.21.0.10",
      internal_port: 80
    )
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "proxies recognized app hostnames to the running runtime" do
    fake_http = FakeHttp.new(FakeResponse.new("200", "whoami response", { "content-type" => "text/plain" }))
    host! @hosted_app.default_route.hostname

    with_http(fake_http) do
      get "/anything?hello=world", headers: { "User-Agent" => "Gateway test" }
    end

    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal "whoami response", response.body
    assert_equal "/anything?hello=world", fake_http.upstream_request.path
    assert_equal @hosted_app.default_route.hostname, fake_http.upstream_request["Host"]
    assert_equal "Gateway test", fake_http.upstream_request["User-Agent"]
    assert_equal 0, @hosted_app.reload.active_request_count
    assert @hosted_app.last_request_at.present?
    assert_equal 1, @hosted_app.app_request_metrics.count
    assert_equal 200, @hosted_app.app_request_metrics.last.status_code
  end

  test "does not intercept the control plane hostname" do
    host! "localhost"

    get "/dashboard"

    assert_response :redirect
    assert_match "/sign_in", response.location
  end

  test "returns unavailable when app hostname has no running runtime" do
    @runtime_instance.update!(status: "crashed")
    host! @hosted_app.default_route.hostname

    get "/"

    assert_response :accepted
    assert_equal "3", response.headers["Retry-After"]
    assert_includes response.body, "App is waking"
  end

  test "requests wake when app hostname has no running runtime" do
    @runtime_instance.destroy!
    @hosted_app.manual_override_to!("sleeping", reason: "test sleeping app")
    host! @hosted_app.default_route.hostname

    assert_enqueued_with(job: WakeAppJob, args: [ @hosted_app.id ]) do
      get "/sleepy"
    end

    assert_response :accepted
    assert_equal "waking", @hosted_app.reload.status
    assert_equal "gateway.wake_requested", @hosted_app.app_events.order(:created_at).last.event_type
    assert @hosted_app.app_request_metrics.last.cold_start?
  end

  test "renders failure page for failed apps without a runtime" do
    @runtime_instance.destroy!
    @hosted_app.manual_override_to!("wake_failed", reason: "test failed app")
    host! @hosted_app.default_route.hostname

    get "/"

    assert_response :bad_gateway
    assert_includes response.media_type, "text/html"
    assert_select "h1", text: "App unavailable"
  end

  test "detects websocket upgrades on the local gateway path" do
    @hosted_app.update!(max_connection_duration_seconds: 120)
    host! @hosted_app.default_route.hostname

    get "/socket", headers: {
      "Connection" => "Upgrade",
      "Upgrade" => "websocket"
    }

    assert_response :not_implemented
    assert_equal "120", response.headers["Retry-After"]
    assert_equal 0, @hosted_app.reload.active_connection_count
  end

  private

  def with_http(fake_http)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |_host, _port, **_options, &block|
      block.call(fake_http)
    end
    yield
  ensure
    Net::HTTP.define_singleton_method(:start) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end
end

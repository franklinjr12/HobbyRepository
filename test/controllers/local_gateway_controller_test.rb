require "test_helper"
require "net/http"

class LocalGatewayControllerTest < ActionDispatch::IntegrationTest
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

    assert_response :service_unavailable
    assert_equal "App is not running", response.body
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

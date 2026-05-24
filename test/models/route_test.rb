require "test_helper"

class RouteTest < ActiveSupport::TestCase
  setup do
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @owner = User.create!(email: "routes@example.com", password: "password123")
    @app = App.create!(name: "Routed", slug: "Routed App", owner: @owner, node: @node)
  end

  test "creates generated route for app" do
    assert_equal "routed-app.localhost", @app.default_route.hostname
    assert_equal "generated_subdomain", @app.default_route.route_type
    assert_equal "verified", @app.default_route.ownership_status
  end

  test "resolves active hostnames" do
    assert_equal @app.default_route, Route.resolve_hostname("ROUTED-APP.localhost")
  end

  test "prevents hostname conflicts" do
    other = Route.new(app: @app, hostname: "routed-app.localhost")

    assert_not other.valid?
    assert_includes other.errors[:hostname], "has already been taken"
  end

  test "custom domains require non-platform hostnames and can be verified" do
    route = @app.routes.create!(hostname: "www.example.com", route_type: "custom_domain", active: false)

    assert route.ownership_token.present?
    assert_equal "pending", route.ownership_status
    assert_match "_platform-verify.www.example.com", route.dns_instruction

    assert route.verify_ownership!(route.ownership_token)
    assert_equal "verified", route.reload.ownership_status

    route.provision_tls!
    assert_equal "active", route.reload.tls_status
    assert route.active?
  end

  test "custom domains cannot use the generated route domain" do
    route = @app.routes.build(hostname: "another.localhost", route_type: "custom_domain")

    assert_not route.valid?
    assert_includes route.errors[:hostname], "must not use the platform route domain"
  end
end

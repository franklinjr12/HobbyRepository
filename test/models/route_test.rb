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
  end

  test "resolves active hostnames" do
    assert_equal @app.default_route, Route.resolve_hostname("ROUTED-APP.localhost")
  end

  test "prevents hostname conflicts" do
    other = Route.new(app: @app, hostname: "routed-app.localhost")

    assert_not other.valid?
    assert_includes other.errors[:hostname], "has already been taken"
  end
end

require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "dashboard@example.com", password: "password123")
    @node = Node.create!(name: "Local", hostname: "dashboard.test", local: true, capacity_memory_bytes: 1.gigabyte)
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  test "shows host capacity reservations" do
    app = @user.apps.create!(name: "Running Dashboard App", node: @node, memory_limit_bytes: 128.megabytes)
    app.manual_override_to!("running", reason: "test dashboard capacity")

    get dashboard_path

    assert_response :success
    assert_select "h2", text: "Host Capacity"
    assert_select "p", text: /1 app running/
    assert_select "p", text: /128 MB reserved/
  end
end

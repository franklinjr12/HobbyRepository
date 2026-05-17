require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "user can sign in and reach dashboard" do
    User.create!(email: "admin@example.com", password: "password123")

    post sign_in_path, params: { email: "admin@example.com", password: "password123" }

    assert_redirected_to dashboard_path
    follow_redirect!
    assert_response :success
    assert_select "h1", "HobbyRepository control plane"
  end

  test "invalid sign in is rejected" do
    post sign_in_path, params: { email: "missing@example.com", password: "password123" }

    assert_response :unprocessable_entity
    assert_select ".alert", "Email or password is incorrect."
  end
end

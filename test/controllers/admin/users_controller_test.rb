require "test_helper"

module Admin
  class UsersControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = User.create!(email: "operator@example.com", password: "password123", admin: true)
      @user = User.create!(email: "owner@example.com", password: "password123")
    end

    test "admin sees user list and new user action" do
      sign_in(@admin)

      get admin_users_path

      assert_response :success
      assert_select "h1", text: "Users"
      assert_select "td", text: @admin.email
      assert_select "td", text: @user.email
      assert_select "a[href='#{new_admin_user_path}']", text: "New user"
    end

    test "admin can create a normal user for onboarding testing" do
      sign_in(@admin)

      assert_difference -> { User.count }, 1 do
        post admin_users_path, params: {
          user: {
            name: "New Tester",
            email: "tester@example.com",
            password: "password123",
            password_confirmation: "password123",
            admin: "0"
          }
        }
      end

      created_user = User.find_by!(email: "tester@example.com")
      assert_redirected_to admin_users_path
      assert_equal "New Tester", created_user.name
      assert_not created_user.admin?
    end

    test "admin can create another admin user" do
      sign_in(@admin)

      assert_difference -> { User.count }, 1 do
        post admin_users_path, params: {
          user: {
            email: "second-admin@example.com",
            password: "password123",
            password_confirmation: "password123",
            admin: "1"
          }
        }
      end

      assert User.find_by!(email: "second-admin@example.com").admin?
    end

    test "invalid user creation renders form errors" do
      sign_in(@admin)

      assert_no_difference -> { User.count } do
        post admin_users_path, params: {
          user: {
            email: "not-an-email",
            password: "short",
            password_confirmation: "short",
            admin: "0"
          }
        }
      end

      assert_response :unprocessable_content
      assert_select ".error-panel"
    end

    test "non-admin cannot access admin user management" do
      sign_in(@user)

      get admin_users_path
      assert_response :not_found

      get new_admin_user_path
      assert_response :not_found

      assert_no_difference -> { User.count } do
        post admin_users_path, params: {
          user: {
            email: "blocked@example.com",
            password: "password123",
            password_confirmation: "password123",
            admin: "1"
          }
        }
      end
      assert_response :not_found
    end

    private

    def sign_in(user)
      post "/sign_in", params: { email: user.email, password: "password123" }
    end
  end
end

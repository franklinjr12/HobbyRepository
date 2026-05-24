require "test_helper"

module Admin
  class TeamsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = User.create!(email: "admin-teams@example.com", password: "password123", admin: true)
      @user = User.create!(email: "member@example.com", password: "password123")
      post sign_in_path, params: { email: @admin.email, password: "password123" }
    end

    test "admin can create update and delete teams" do
      assert_difference -> { Team.count }, 1 do
        post admin_teams_path, params: {
          team: {
            name: "Product Ops",
            slug: "product-ops"
          }
        }
      end

      team = Team.find_by!(slug: "product-ops")
      assert_redirected_to edit_admin_team_path(team)

      patch admin_team_path(team), params: {
        team: {
          name: "Product Operations",
          slug: "product-operations"
        }
      }

      assert_redirected_to edit_admin_team_path(team)
      assert_equal "Product Operations", team.reload.name

      assert_difference -> { Team.count }, -1 do
        delete admin_team_path(team)
      end

      assert_redirected_to admin_teams_path
    end

    test "admin can add update and remove team memberships" do
      team = Team.create!(name: "Runtime Team")

      assert_difference -> { TeamMembership.count }, 1 do
        post admin_team_team_memberships_path(team), params: {
          team_membership: {
            user_id: @user.id,
            role: "developer"
          }
        }
      end

      membership = team.team_memberships.find_by!(user: @user)
      assert_redirected_to edit_admin_team_path(team)
      assert_equal "developer", membership.role

      patch admin_team_team_membership_path(team, membership), params: {
        team_membership: {
          role: "admin"
        }
      }

      assert_redirected_to edit_admin_team_path(team)
      assert_equal "admin", membership.reload.role

      assert_difference -> { TeamMembership.count }, -1 do
        delete admin_team_team_membership_path(team, membership)
      end

      assert_redirected_to edit_admin_team_path(team)
    end

    test "non-admin cannot manage teams" do
      delete sign_out_path
      post sign_in_path, params: { email: @user.email, password: "password123" }

      get admin_teams_path

      assert_response :not_found
    end
  end
end

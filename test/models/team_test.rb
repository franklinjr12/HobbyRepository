require "test_helper"

class TeamTest < ActiveSupport::TestCase
  test "normalizes slug and exposes membership roles" do
    user = User.create!(email: "team-member@example.com", password: "password123")
    team = Team.create!(name: "Core Platform")
    membership = team.team_memberships.create!(user: user, role: "developer")

    assert_equal "core-platform", team.slug
    assert_equal membership, team.membership_for(user)
    assert membership.can_manage_apps?
    assert_not membership.can_administer_team?
  end
end

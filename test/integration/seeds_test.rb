require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  test "loads demo control-plane data idempotently" do
    Rails.application.load_seed

    first_counts = seeded_counts

    Rails.application.load_seed

    assert_equal first_counts, seeded_counts

    admin = User.find_by!(email: "admin@example.com")
    assert admin.admin?
    assert_equal "Platform Admin", admin.name

    seeded_apps = admin.apps.where(slug: %w[
      sleepy-landing-page
      warm-whoami-api
      broken-health-check
      draft-private-tool
    ])

    assert_equal 4, seeded_apps.count
    assert_equal "sleeping", seeded_apps.find_by!(slug: "sleepy-landing-page").status
    assert_equal "running", seeded_apps.find_by!(slug: "warm-whoami-api").status
    assert_equal "wake_failed", seeded_apps.find_by!(slug: "broken-health-check").status
    assert_equal "created", seeded_apps.find_by!(slug: "draft-private-tool").status
    assert_equal "********", seeded_apps.find_by!(slug: "draft-private-tool")
                                .environment_variables.find_by!(key: "DATABASE_URL")
                                .display_value
  end

  private

  def seeded_counts
    {
      users: User.count,
      nodes: Node.count,
      apps: App.count,
      deployments: Deployment.count,
      runtime_instances: RuntimeInstance.count,
      environment_variables: EnvironmentVariable.count,
      app_events: AppEvent.count,
      routes: Route.count
    }
  end
end

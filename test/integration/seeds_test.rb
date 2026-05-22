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
    sample_user = User.find_by!(email: "user@example.com")
    assert_not sample_user.admin?
    assert_equal "Sample User", sample_user.name

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
    draft_database = seeded_apps.find_by!(slug: "draft-private-tool").database_resource
    assert_equal "available", draft_database.status
    assert_equal "********", draft_database.display_runtime_environment.fetch("DATABASE_URL")
    assert_equal 1, draft_database.database_backups.count
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
      database_resources: DatabaseResource.count,
      database_backups: DatabaseBackup.count,
      app_logs: AppLog.count,
      app_events: AppEvent.count,
      routes: Route.count
    }
  end
end

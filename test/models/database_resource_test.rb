require "test_helper"

class DatabaseResourceTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "database-owner@example.com", password: "password123")
    Node.ensure_local!
    @app = @owner.apps.create!(name: "Database App", slug: "database-app")
  end

  test "assigns generated credentials and runtime environment" do
    database_resource = @app.create_database_resource!(status: "available")

    assert_equal "postgres", database_resource.database_type
    assert_equal "app_database_app_#{@app.id}", database_resource.database_name
    assert_equal "app_database_app_#{@app.id}_user", database_resource.username
    assert_not_equal database_resource.password, database_resource.encrypted_password
    assert_equal "********", database_resource.display_runtime_environment.fetch("DATABASE_URL")
    assert_match database_resource.username, database_resource.runtime_environment.fetch("DATABASE_URL")
    assert_equal database_resource.database_name, database_resource.runtime_environment.fetch("DATABASE_NAME")
  end

  test "does not expose runtime environment until available" do
    database_resource = @app.create_database_resource!

    assert_equal "pending", database_resource.status
    assert_empty database_resource.runtime_environment
  end

  test "rotates credentials without storing raw password" do
    database_resource = @app.create_database_resource!(status: "available")
    original_password = database_resource.password

    database_resource.rotate_credentials!

    assert_not_equal original_password, database_resource.reload.password
    assert database_resource.credentials_rotated_at.present?
    assert_not_includes database_resource.encrypted_password, database_resource.password
    assert_equal "database.credentials_rotated", @app.app_events.order(:created_at).last.event_type
  end
end

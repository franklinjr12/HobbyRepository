require "test_helper"

class DatabaseBackupExporterTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "backup-owner@example.com", password: "password123")
    Node.ensure_local!
    @app = @owner.apps.create!(name: "Backup App", slug: "backup-app")
    @database_resource = @app.create_database_resource!(status: "available")
  end

  test "stores successful pg dump output encrypted" do
    exporter = DatabaseBackupExporter.new(
      runner: ->(_database_resource) {
        DatabaseBackupExporter::Dump.new(true, "Database backup completed.", "CREATE TABLE examples();\n")
      }
    )

    result = exporter.export(@database_resource)

    assert result.success?
    backup = result.backup
    assert_equal "completed", backup.status
    assert_equal "CREATE TABLE examples();\n", backup.content
    assert_not_includes backup.encrypted_content, "CREATE TABLE"
    assert_equal "database.backup_completed", @app.app_events.order(:created_at).last.event_type
  end

  test "records backup failures" do
    exporter = DatabaseBackupExporter.new(
      runner: ->(_database_resource) {
        DatabaseBackupExporter::Dump.new(false, "permission denied", nil)
      }
    )

    result = exporter.export(@database_resource)

    assert_not result.success?
    backup = result.backup
    assert_equal "failed", backup.status
    assert_equal "permission denied", backup.failure_message
    assert_equal "database.backup_failed", @app.app_events.order(:created_at).last.event_type
  end
end

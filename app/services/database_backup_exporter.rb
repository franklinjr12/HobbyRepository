require "open3"

class DatabaseBackupExporter
  Result = Data.define(:success, :message, :backup) do
    alias success? success
  end

  def initialize(runner: nil)
    @runner = runner || method(:run_pg_dump)
  end

  def export(database_resource)
    backup = database_resource.database_backups.create!
    dump = runner.call(database_resource)
    unless dump.success?
      backup.mark_failed!(dump.message)
      database_resource.app.record_event!(
        "database.backup_failed",
        "Database backup failed for #{database_resource.app.name}",
        metadata: backup.public_metadata.merge(error: dump.message)
      )
      return Result.new(false, dump.message, backup)
    end

    backup.mark_completed!(dump.content)

    database_resource.app.record_event!(
      "database.backup_completed",
      "Database backup completed for #{database_resource.app.name}",
      metadata: backup.public_metadata
    )

    Result.new(true, "Database backup completed.", backup)
  rescue ActiveRecord::ActiveRecordError => error
    backup&.mark_failed!(error.message)
    database_resource.app.record_event!(
      "database.backup_failed",
      "Database backup failed for #{database_resource.app.name}",
      metadata: { database_resource_id: database_resource.id, error: error.message }
    )
    Result.new(false, error.message, backup)
  end

  private

  Dump = Data.define(:success, :message, :content) do
    alias success? success
  end

  attr_reader :runner

  def run_pg_dump(database_resource)
    stdout, stderr, status = Open3.capture3(
      { "PGPASSWORD" => database_resource.password },
      "pg_dump",
      "--dbname=#{dump_url(database_resource)}",
      "--no-owner",
      "--no-privileges"
    )

    return Dump.new(true, "Database backup completed.", stdout) if status.success?

    Dump.new(false, stderr.presence || "pg_dump failed.", nil)
  rescue SystemCallError => error
    Dump.new(false, error.message, nil)
  end

  def dump_url(database_resource)
    URI::Generic.build(
      scheme: "postgres",
      userinfo: database_resource.username,
      host: database_resource.host,
      port: database_resource.port,
      path: "/#{database_resource.database_name}"
    ).to_s
  end
end

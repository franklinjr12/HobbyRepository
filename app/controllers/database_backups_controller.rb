class DatabaseBackupsController < ApplicationController
  before_action :set_app
  before_action :set_backup

  def show
    return redirect_to @app, alert: "Backup is not ready for download." unless @backup.completed?

    send_data(
      @backup.content,
      filename: @backup.filename,
      type: "application/sql",
      disposition: "attachment"
    )
  end

  private

  def set_app
    @app = current_user.apps.find(params.expect(:app_id))
  end

  def set_backup
    @backup = @app.database_resource.database_backups.find(params.expect(:id))
  end
end

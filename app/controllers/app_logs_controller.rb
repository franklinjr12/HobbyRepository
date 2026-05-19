class AppLogsController < ApplicationController
  before_action :set_app

  def index
    @runtime_instances = @app.runtime_instances.order(created_at: :desc)
    @deployments = @app.deployments.order(created_at: :desc)
    @logs = filtered_logs.recent(300)
    @auto_refresh = ActiveModel::Type::Boolean.new.cast(params[:auto_refresh])
  end

  def collect
    result = RuntimeAgent.build.get_logs(@app)
    return redirect_to app_app_logs_path(@app), notice: "Logs refreshed." if result.success?

    redirect_to app_app_logs_path(@app), alert: result.error.message
  end

  private

  def set_app
    @app = current_user.apps.find(params.expect(:app_id))
  end

  def filtered_logs
    @app.app_logs
        .includes(:runtime_instance, :deployment)
        .for_runtime_instance(params[:runtime_instance_id])
        .for_deployment(params[:deployment_id])
        .text_search(params[:q])
  end
end

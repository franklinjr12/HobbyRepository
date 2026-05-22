module Admin
  class AppsController < BaseController
    def index
      @apps = App.includes(:owner, :routes, :runtime_metric_snapshots, :runtime_instances)
                 .order(:name)
    end

    def stop
      app = App.find(params.expect(:id))
      result = runtime_agent.stop_app(app)
      return redirect_to admin_apps_path, notice: "#{app.name} stopped." if result.success?

      redirect_to admin_apps_path, alert: result.error.message
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      redirect_to admin_apps_path, alert: error.message
    end

    private

    def runtime_agent
      RuntimeAgent.build
    end
  end
end

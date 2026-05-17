class DashboardController < ApplicationController
  def index
    @apps = current_user.apps.includes(:routes, :deployments).order(updated_at: :desc).limit(5)
    @recent_events = AppEvent.joins(:app)
                             .where(apps: { owner_id: current_user.id })
                             .order(created_at: :desc)
                             .limit(8)
    @milestones = [
      "Rails control plane",
      "Manual runtime control",
      "Sleep/wake lifecycle",
      "Gateway activator",
      "Persistence and safety",
      "Observability and recovery"
    ]
  end
end

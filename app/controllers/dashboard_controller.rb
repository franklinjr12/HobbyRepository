class DashboardController < ApplicationController
  def index
    @local_node = Node.ensure_local!
    @apps = current_user.apps.includes(:routes, :deployments).order(updated_at: :desc).limit(5)
    @running_app_count = App.running.count
    @reserved_memory_bytes = App.running.sum(:memory_limit_bytes)
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

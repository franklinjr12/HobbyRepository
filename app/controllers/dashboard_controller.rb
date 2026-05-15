class DashboardController < ApplicationController
  def index
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

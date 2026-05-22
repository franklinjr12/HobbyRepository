module Admin
  class HealthController < BaseController
    def show
      @health = PlatformHealth.new.check
      @nodes = Node.order(local: :desc, name: :asc)
      @running_app_count = App.running.count
      @recent_failures = AppEvent.where(
        "event_type LIKE :failed OR event_type LIKE :missing OR event_type LIKE :orphaned",
        failed: "%failed%",
        missing: "%missing%",
        orphaned: "%orphaned%"
      ).order(created_at: :desc).limit(10)
    end
  end
end

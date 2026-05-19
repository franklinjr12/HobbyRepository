class IdleSleepJob < ApplicationJob
  queue_as :default

  def perform
    App.running.find_each do |app|
      drain_or_sleep_running_app(app)
    end

    App.draining.find_each do |app|
      next if app.active_runtime_activity? && !app.drain_timeout_expired?

      AppSleeper.new.sleep(app, requested_by: "platform", trigger: "idle_timeout", force: true)
    end
  end

  private

  def drain_or_sleep_running_app(app)
    return unless app.idle_timeout_reached?

    if app.active_runtime_activity?
      app.with_lock do
        app.reload
        next unless app.status == "running" && app.idle_timeout_reached? && app.active_runtime_activity?

        app.begin_sleep_drain!(
          requested_by: "platform",
          trigger: "idle_timeout",
          wait_for_activity: true
        )
      end
    elsif app.idle_sleep_due?
      AppSleeper.new.sleep(app, requested_by: "platform", trigger: "idle_timeout")
    end
  end
end

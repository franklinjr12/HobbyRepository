class AppSleeper
  def initialize(runtime_agent: RuntimeAgent.build)
    @runtime_agent = runtime_agent
  end

  def sleep(app, requested_by:, trigger:, force: false)
    app.with_lock do
      app.reload
      return active_activity_failure(app) if !force && app.active_runtime_activity?
      return not_running_failure(app) unless sleepable_status?(app.status)

      return RuntimeAgent::Result.success(command: "sleep_app", skipped: true) if app.status == "sleeping"
      if app.status == "stopped"
        app.mark_sleep_succeeded!(requested_by: requested_by, trigger: trigger)
        return RuntimeAgent::Result.success(command: "sleep_app", skipped: true, app_status: "sleeping")
      end

      app.begin_sleep_drain!(requested_by: requested_by, trigger: trigger, force: force)
    end

    result = runtime_agent.stop_app(app)
    unless result.success?
      app.record_event!(
        "sleep.failed",
        "Sleep failed for #{app.name}",
        metadata: { error: result.error.to_h }
      )
      return result
    end

    app.with_lock do
      app.reload
      app.mark_sleep_succeeded!(requested_by: requested_by, trigger: trigger)
    end

    RuntimeAgent::Result.success(result.payload.merge(command: "sleep_app", app_status: "sleeping"))
  end

  private

  attr_reader :runtime_agent

  def sleepable_status?(status)
    %w[running draining stopping stopped sleeping].include?(status)
  end

  def active_activity_failure(app)
    RuntimeAgent::Result.failure(
      RuntimeAgent::Error.new(
        "active_requests",
        "App still has active traffic and cannot sleep yet",
        nil,
        nil,
        nil,
        {
          active_request_count: app.active_request_count,
          active_connection_count: app.active_connection_count
        }
      )
    )
  end

  def not_running_failure(app)
    RuntimeAgent::Result.failure(
      RuntimeAgent::Error.new(
        "not_sleepable",
        "App cannot sleep from #{app.status}",
        nil,
        nil,
        nil,
        { app_status: app.status }
      )
    )
  end
end

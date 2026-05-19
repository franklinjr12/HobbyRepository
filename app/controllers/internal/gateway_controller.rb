module Internal
  class GatewayController < ActionController::API
    RETRY_AFTER_SECONDS = 3
    WAKEABLE_STATUSES = %w[created sleeping stopped crashed unhealthy wake_failed].freeze

    before_action :authenticate_gateway!

    def resolve
      route = resolve_route
      return render_unknown_hostname unless route

      app = route.app
      runtime_instance = latest_running_runtime(app)

      if app.status == "running" && runtime_instance&.internal_target_ready?
        app.record_request_activity!
        render json: resolution_payload(app, route, runtime_instance)
      else
        render json: wake_required_payload(app, route), status: :accepted
      end
    end

    def wake
      app = resolve_app
      return render_unknown_hostname unless app

      wake_was_enqueued = request_wake(app)
      app.reload

      render json: wake_status_payload(app, wake_was_enqueued: wake_was_enqueued), status: :accepted
    end

    def wake_status
      app = resolve_app
      return render_unknown_hostname unless app

      render json: wake_status_payload(app)
    end

    def activity
      app = resolve_app
      return render_unknown_hostname unless app

      activity_result = record_activity(app)
      app.record_event!(
        "gateway.activity_reported",
        "Gateway reported traffic for #{app.name}",
        metadata: {
          hostname: hostname_param,
          event: activity_event,
          method: params[:request_method],
          path: params[:path],
          status_code: status_code_param,
          cold_start: cold_start_param,
          wake_duration_ms: wake_duration_ms_param
        }.compact
      )
      record_request_metric(app)

      render json: {
        status: "recorded",
        app_id: app.id,
        last_activity_at: app.last_activity_at.iso8601,
        last_request_at: app.last_request_at&.iso8601,
        active_request_count: app.active_request_count,
        active_connection_count: app.active_connection_count,
        sleep_cancelled: activity_result == :sleep_cancelled
      }
    end

    private

    def authenticate_gateway!
      expected_token = ENV["GATEWAY_SHARED_SECRET"]
      return if expected_token.blank? && !Rails.env.production?
      return render(json: { status: "unauthorized" }, status: :unauthorized) if expected_token.blank?

      token = request.authorization.to_s.delete_prefix("Bearer ").presence
      return if ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected_token.to_s)

      render json: { status: "unauthorized" }, status: :unauthorized
    end

    def resolve_route
      Route.resolve_hostname(hostname_param)
    end

    def resolve_app
      return App.find_by(id: params[:app_id]) if params[:app_id].present?

      resolve_route&.app
    end

    def hostname_param
      params.permit(:hostname)[:hostname].to_s.split(":").first.to_s.downcase
    end

    def render_unknown_hostname
      render json: {
        status: "not_found",
        hostname: hostname_param
      }, status: :not_found
    end

    def latest_running_runtime(app)
      app.runtime_instances
         .where(status: "running")
         .where.not(internal_host: nil)
         .where.not(internal_port: nil)
         .order(created_at: :desc)
         .first
    end

    def resolution_payload(app, route, runtime_instance)
      {
        status: "running",
        app_id: app.id,
        app_status: app.status,
        hostname: route.hostname,
        internal_target: internal_target_payload(runtime_instance)
      }
    end

    def wake_required_payload(app, route)
      {
        status: "wake_required",
        app_id: app.id,
        app_status: app.status,
        hostname: route.hostname,
        retry_after: RETRY_AFTER_SECONDS
      }
    end

    def wake_status_payload(app, wake_was_enqueued: false)
      {
        status: wake_status_for(app),
        app_id: app.id,
        app_status: app.status,
        wake_enqueued: wake_was_enqueued,
        retry_after: retry_after_for(app)
      }.compact
    end

    def wake_status_for(app)
      return "ready" if app.status == "running"
      return "waking" if app.status == "waking"
      return "failed" if app.status == "wake_failed"

      "wake_required"
    end

    def retry_after_for(app)
      RETRY_AFTER_SECONDS unless app.status == "running"
    end

    def request_wake(app)
      should_enqueue = false

      app.with_lock do
        app.reload

        if app.status == "waking" || app.status == "running"
          should_enqueue = false
        elsif WAKEABLE_STATUSES.include?(app.status)
          app.manual_override_to!("waking", reason: "gateway wake request")
          app.record_request_metric!(
            cold_start: true,
            request_method: params.permit(:request_method)[:request_method],
            path: params.permit(:path)[:path]
          )
          app.record_event!(
            "gateway.wake_requested",
            "Gateway requested wake for #{app.name}",
            metadata: { hostname: hostname_param.presence, source: "gateway" }.compact
          )
          should_enqueue = true
        end
      end

      WakeAppJob.perform_later(app.id) if should_enqueue
      should_enqueue
    end

    def record_activity(app)
      was_draining = app.status == "draining"

      case activity_event
      when "request_started"
        app.record_request_started!(connection: connection_activity?)
      when "request_finished"
        app.record_request_finished!(connection: connection_activity?)
      else
        app.record_request_activity!
      end

      was_draining && app.reload.status == "running" ? :sleep_cancelled : :recorded
    end

    def activity_event
      params.permit(:event)[:event].presence || "request"
    end

    def connection_activity?
      ActiveModel::Type::Boolean.new.cast(params.permit(:connection)[:connection])
    end

    def record_request_metric(app)
      return unless metric_recordable_event?

      app.record_request_metric!(
        status_code: status_code_param,
        cold_start: cold_start_param,
        wake_duration_ms: wake_duration_ms_param,
        request_method: params.permit(:request_method)[:request_method],
        path: params.permit(:path)[:path]
      )
    end

    def metric_recordable_event?
      activity_event != "request_finished" || status_code_param.present?
    end

    def status_code_param
      value = params.permit(:status_code)[:status_code]
      return unless value.to_s.match?(/\A\d+\z/)

      value.to_i
    end

    def cold_start_param
      ActiveModel::Type::Boolean.new.cast(params.permit(:cold_start)[:cold_start])
    end

    def wake_duration_ms_param
      value = params.permit(:wake_duration_ms)[:wake_duration_ms]
      return unless value.to_s.match?(/\A\d+\z/)

      value.to_i
    end

    def internal_target_payload(runtime_instance)
      {
        scheme: "http",
        host: runtime_instance.internal_host,
        port: runtime_instance.internal_port,
        url: "http://#{runtime_instance.internal_host}:#{runtime_instance.internal_port}"
      }
    end
  end
end

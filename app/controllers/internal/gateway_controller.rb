module Internal
  class GatewayController < ActionController::API
    RETRY_AFTER_SECONDS = 3
    WAKEABLE_STATUSES = %w[created sleeping stopped crashed unhealthy wake_failed].freeze
    FAILED_STATUSES = %w[crashed unhealthy wake_failed].freeze
    FAILURE_STATUS = :bad_gateway

    before_action :authenticate_gateway!

    def resolve
      route = resolve_route
      return render_unknown_hostname unless route

      app = route.app
      runtime_instance = latest_running_runtime(app)

      if app.status == "running" && runtime_instance&.internal_target_ready?
        app.record_request_activity!
        render json: resolution_payload(app, route, runtime_instance)
      elsif failed_app?(app)
        render_app_failed(app)
      else
        render_wake_required(app, route)
      end
    end

    def wake
      app = resolve_app
      return render_unknown_hostname unless app

      wake_was_enqueued = request_wake(app)
      app.reload

      render_wake_status(app, wake_was_enqueued: wake_was_enqueued, status: :accepted)
    end

    def wake_status
      app = resolve_app
      return render_unknown_hostname unless app

      if failed_app?(app)
        render_app_failed(app)
      else
        render_wake_status(app)
      end
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
      expected_token = ENV["PLATFORM_INTERNAL_TOKEN"].presence || ENV["GATEWAY_SHARED_SECRET"]
      return if expected_token.blank? && !Rails.env.production?

      if expected_token.blank?
        log_unauthorized_gateway_attempt!("missing internal token configuration")
        return render(json: { status: "unauthorized" }, status: :unauthorized)
      end

      token = request.authorization.to_s.delete_prefix("Bearer ").presence
      return if ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected_token.to_s)

      log_unauthorized_gateway_attempt!("invalid internal token")
      render json: { status: "unauthorized" }, status: :unauthorized
    end

    def log_unauthorized_gateway_attempt!(reason)
      Rails.logger.warn(
        "Unauthorized internal gateway request: reason=#{reason.inspect} " \
        "path=#{request.fullpath.inspect} remote_ip=#{request.remote_ip.inspect}"
      )
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
      if html_request?
        render_failure_page(
          title: "App not found",
          heading: "App not found",
          message: "This hostname is not attached to an app on this platform.",
          detail: "Check the address and try again.",
          status: :not_found
        )
      else
        render json: {
          status: "not_found"
        }, status: :not_found
      end
    end

    def render_wake_required(app, route)
      response.set_header("Retry-After", RETRY_AFTER_SECONDS.to_s)
      render json: wake_required_payload(app, route), status: :accepted
    end

    def render_wake_status(app, wake_was_enqueued: false, status: :ok)
      response.set_header("Retry-After", RETRY_AFTER_SECONDS.to_s) unless app.status == "running"
      render json: wake_status_payload(app, wake_was_enqueued: wake_was_enqueued), status: status
    end

    def render_app_failed(app)
      if html_request?
        render_failure_page(
          title: "App unavailable",
          heading: "App unavailable",
          message: app_unavailable_message(app),
          detail: "Reason: #{failure_reason_label(failure_reason_for(app))}.",
          dashboard_path: owner_dashboard_path(app),
          status: FAILURE_STATUS
        )
      else
        render json: failed_app_payload(app), status: FAILURE_STATUS
      end
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
      return failed_app_payload(app).merge(wake_enqueued: wake_was_enqueued) if failed_app?(app)

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

    def failed_app_payload(app)
      {
        status: "failed",
        app_id: app.id,
        app_status: app.status,
        reason: failure_reason_for(app)
      }
    end

    def failed_app?(app)
      FAILED_STATUSES.include?(app.status)
    end

    def failure_reason_for(app)
      latest_event = app.app_events.order(created_at: :desc).find do |event|
        event.event_type.in?(%w[runtime.start_failed health_check.failed])
      end
      latest_runtime = app.runtime_instances.order(created_at: :desc).first
      latest_metric = app.cold_start_metrics.failed.order(started_at: :desc).first
      failure_text = [
        app.status,
        latest_event&.event_type,
        latest_event&.metadata,
        latest_runtime&.status,
        latest_runtime&.failure_message,
        latest_runtime&.health_check_result,
        latest_metric&.failure_message
      ].compact.join(" ").downcase

      if failure_text.match?(/image_(unavailable|pull)|could not be pulled/)
        return "image_pull_failed"
      end

      return "timeout" if failure_text.match?(/timeout|timed out|before timing out/)
      return "health_check_failed" if failure_text.match?(/health_check|health check|readiness/)
      return "container_crashed" if failure_text.match?(/crash|start_failed|container start failed/)

      "container_crashed"
    end

    def failure_reason_label(reason)
      {
        "image_pull_failed" => "Image pull failed",
        "container_crashed" => "Container crashed",
        "health_check_failed" => "Health check failed",
        "timeout" => "Timeout"
      }.fetch(reason, "App failed")
    end

    def app_unavailable_message(app)
      "#{app.name} could not be started."
    end

    def owner_dashboard_path(app)
      return unless owner_authenticated?(app)

      Rails.application.routes.url_helpers.app_path(app)
    end

    def owner_authenticated?(app)
      session[:user_id].present? && session[:user_id].to_i == app.owner_id
    rescue StandardError
      false
    end

    def html_request?
      request.headers["Accept"].to_s.include?("text/html")
    end

    def render_failure_page(title:, heading:, message:, detail:, status:, dashboard_path: nil)
      html = ApplicationController.render(
        template: "internal/gateway/failure",
        layout: false,
        locals: {
          title: title,
          heading: heading,
          message: message,
          detail: detail,
          dashboard_path: dashboard_path
        }
      )
      render body: html, content_type: "text/html", status: status
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

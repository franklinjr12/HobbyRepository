require "net/http"

class LocalGatewayController < ApplicationController
  RETRY_AFTER_SECONDS = 3
  WAKEABLE_STATUSES = %w[created sleeping stopped crashed unhealthy wake_failed].freeze
  FAILED_STATUSES = %w[crashed unhealthy wake_failed].freeze

  HOP_BY_HOP_HEADERS = %w[
    connection
    keep-alive
    proxy-authenticate
    proxy-authorization
    te
    trailer
    transfer-encoding
    upgrade
  ].freeze

  skip_before_action :require_authentication
  skip_forgery_protection

  def proxy
    route = Route.resolve_hostname(request.host)
    return render plain: "App not found", status: :not_found unless route

    app = route.app
    runtime_instance = latest_running_runtime(app)
    return render_failed_app(app) if failed_app?(app) && runtime_instance.blank?
    return render_waking_app(app, request_wake(app)) unless runtime_instance
    return render_websocket_policy(app) if websocket_upgrade?

    proxy_started_at = Time.current
    app.record_request_started!
    upstream_response = forward_request(runtime_instance)
    copy_response_headers(upstream_response)
    app.record_request_metric!(
      status_code: upstream_response.code.to_i,
      request_method: request.request_method,
      path: request.path
    )
    render body: upstream_response.body, status: upstream_response.code.to_i
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout, SocketError => error
    render plain: "App gateway error: #{error.message}", status: :bad_gateway
  ensure
    app&.record_request_finished!(at: Time.current) if proxy_started_at
  end

  private

  def latest_running_runtime(app)
    app.runtime_instances
       .where(status: "running")
       .where.not(internal_host: nil)
       .where.not(internal_port: nil)
       .order(created_at: :desc)
       .first
  end

  def failed_app?(app)
    FAILED_STATUSES.include?(app.status)
  end

  def request_wake(app)
    should_enqueue = false

    app.with_lock do
      app.reload

      if app.status == "waking" || app.status == "running"
        should_enqueue = false
      elsif WAKEABLE_STATUSES.include?(app.status)
        app.manual_override_to!("waking", reason: "local gateway wake request")
        app.record_request_metric!(
          cold_start: true,
          request_method: request.request_method,
          path: request.path
        )
        app.record_event!(
          "gateway.wake_requested",
          "Gateway requested wake for #{app.name}",
          metadata: { hostname: request.host, source: "local_gateway" }
        )
        should_enqueue = true
      end
    end

    WakeAppJob.perform_later(app.id) if should_enqueue
    should_enqueue
  end

  def render_waking_app(app, wake_enqueued)
    response.set_header("Retry-After", RETRY_AFTER_SECONDS.to_s)
    render_failure_page(
      title: "App is waking",
      heading: "App is waking",
      message: "#{app.name} is starting.",
      detail: wake_enqueued ? "Refresh in a few seconds." : "Startup is already in progress.",
      status: :accepted
    )
  end

  def render_failed_app(app)
    render_failure_page(
      title: "App unavailable",
      heading: "App unavailable",
      message: "#{app.name} could not be started.",
      detail: "Check the app dashboard for runtime logs.",
      status: :bad_gateway
    )
  end

  def render_websocket_policy(app)
    app.record_request_started!(connection: true)
    app.record_request_finished!(connection: true)
    response.set_header("Retry-After", app.max_connection_duration_seconds.to_s)
    render plain: "WebSocket traffic is supported by the external gateway path.", status: :not_implemented
  end

  def render_failure_page(title:, heading:, message:, detail:, status:)
    html = ApplicationController.render(
      template: "internal/gateway/failure",
      layout: false,
      locals: {
        title: title,
        heading: heading,
        message: message,
        detail: detail,
        dashboard_path: nil
      }
    )
    render body: html, content_type: "text/html", status: status
  end

  def websocket_upgrade?
    request.headers["Upgrade"].to_s.casecmp("websocket").zero?
  end

  def forward_request(runtime_instance)
    Net::HTTP.start(
      runtime_instance.internal_host,
      runtime_instance.internal_port,
      open_timeout: 5,
      read_timeout: 30
    ) do |http|
      http.request(upstream_request)
    end
  end

  def upstream_request
    request_class = Net::HTTP.const_get(request.request_method.capitalize)
    upstream_request = request_class.new(request.original_fullpath)
    copy_request_headers(upstream_request)
    upstream_request.body = request.raw_post if request.raw_post.present?
    upstream_request
  end

  def copy_request_headers(upstream_request)
    request.headers.each do |key, value|
      next unless key.start_with?("HTTP_")

      header_name = key.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-")
      next if HOP_BY_HOP_HEADERS.include?(header_name.downcase)

      upstream_request[header_name] = value
    end

    upstream_request["Host"] = request.host_with_port
  end

  def copy_response_headers(upstream_response)
    upstream_response.each_header do |key, value|
      next if HOP_BY_HOP_HEADERS.include?(key.downcase)

      response.set_header(key, value)
    end
  end
end

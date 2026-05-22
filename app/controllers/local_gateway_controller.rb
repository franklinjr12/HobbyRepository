require "net/http"

class LocalGatewayController < ApplicationController
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

    runtime_instance = latest_running_runtime(route.app)
    return render plain: "App is not running", status: :service_unavailable unless runtime_instance

    upstream_response = forward_request(runtime_instance)
    copy_response_headers(upstream_response)
    render body: upstream_response.body, status: upstream_response.code.to_i
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout, SocketError => error
    render plain: "App gateway error: #{error.message}", status: :bad_gateway
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

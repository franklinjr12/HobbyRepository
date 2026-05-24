module Internal
  class NodeHeartbeatsController < ActionController::API
    before_action :authenticate_node_agent!

    def create
      Node.mark_stale_unhealthy!
      node = resolve_node
      node.heartbeat!(
        status: heartbeat_status,
        capacity_cpu: decimal_param(:capacity_cpu),
        capacity_memory_bytes: integer_param(:capacity_memory_bytes)
      )

      render json: {
        status: "recorded",
        node_id: node.id,
        node_status: node.status,
        last_heartbeat_at: node.last_heartbeat_at.iso8601
      }
    end

    private

    def authenticate_node_agent!
      expected_token = ENV["PLATFORM_INTERNAL_TOKEN"].presence || ENV["NODE_AGENT_SHARED_SECRET"]
      return if expected_token.blank? && !Rails.env.production?

      if expected_token.blank?
        log_unauthorized_node_attempt!("missing internal token configuration")
        return render(json: { status: "unauthorized" }, status: :unauthorized)
      end

      token = request.authorization.to_s.delete_prefix("Bearer ").presence
      return if ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected_token.to_s)

      log_unauthorized_node_attempt!("invalid internal token")
      render json: { status: "unauthorized" }, status: :unauthorized
    end

    def log_unauthorized_node_attempt!(reason)
      Rails.logger.warn(
        "Unauthorized internal node heartbeat: reason=#{reason.inspect} " \
        "path=#{request.fullpath.inspect} remote_ip=#{request.remote_ip.inspect}"
      )
    end

    def resolve_node
      if heartbeat_params[:local].present? && ActiveModel::Type::Boolean.new.cast(heartbeat_params[:local])
        Node.ensure_local!
      else
        Node.find_or_initialize_by(hostname: heartbeat_hostname).tap do |node|
          node.name = heartbeat_name
          node.local = false if node.new_record?
          node.status ||= "active"
          node.save! if node.new_record? || node.changed?
        end
      end
    end

    def heartbeat_params
      params.permit(:name, :hostname, :status, :capacity_cpu, :capacity_memory_bytes, :local)
    end

    def heartbeat_hostname
      heartbeat_params[:hostname].presence || request.remote_ip
    end

    def heartbeat_name
      heartbeat_params[:name].presence || heartbeat_hostname
    end

    def heartbeat_status
      status = heartbeat_params[:status].presence || "active"
      Node::STATUSES.include?(status) ? status : "degraded"
    end

    def decimal_param(key)
      value = heartbeat_params[key]
      return if value.blank?

      BigDecimal(value.to_s)
    end

    def integer_param(key)
      value = heartbeat_params[key]
      return if value.blank?

      Integer(value)
    end
  end
end

class PlatformHealth
  def initialize(runtime_agent: RuntimeAgent.build)
    @runtime_agent = runtime_agent
  end

  def check
    {
      rails: rails_status,
      runtime_agent: runtime_agent_status,
      gateway: gateway_status
    }
  end

  private

  attr_reader :runtime_agent

  def rails_status
    { ok: true, message: "Rails is accepting requests." }
  end

  def runtime_agent_status
    if runtime_agent.respond_to?(:platform_available?) && runtime_agent.platform_available?
      { ok: true, message: "Runtime agent can reach Docker." }
    else
      { ok: false, message: "Runtime agent cannot reach Docker." }
    end
  rescue RuntimeAgent::Failure
    { ok: false, message: "Runtime agent check failed." }
  end

  def gateway_status
    route = Rails.application.routes.url_helpers.internal_resolve_path
    { ok: true, message: "Gateway endpoint is routed at #{route}." }
  rescue StandardError => error
    { ok: false, message: "Gateway route check failed: #{error.message}" }
  end
end

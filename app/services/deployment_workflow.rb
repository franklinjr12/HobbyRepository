class DeploymentWorkflow
  Result = Data.define(:success, :deployment, :error) do
    alias success? success

    def self.success(deployment)
      new(true, deployment, nil)
    end

    def self.failure(error)
      new(false, nil, error)
    end
  end

  def initialize(runtime_agent: RuntimeAgent.build)
    @runtime_agent = runtime_agent
  end

  def deploy_image(app, image_reference:, requested_by:, start: false)
    image_reference = image_reference.to_s.strip
    return validation_failure("must be a valid container image reference") unless Deployment.valid_image_reference?(image_reference)

    should_start = start || app.status == "running"
    stop_running_app(app) if app.status == "running"

    deployment = nil
    app.deployments.transaction do
      app.update!(
        image_reference: image_reference,
        internal_port: app.internal_port,
        health_check_kind: app.health_check_kind,
        health_check_path: app.health_check_path
      )
      deployment = create_current_deployment(app, image_reference: image_reference)
      app.record_event!(
        "deployment.deployed",
        "Deployment #{deployment.id} became current",
        metadata: deployment_metadata(deployment).merge(requested_by: requested_by)
      )
    end

    start_or_sleep(app, deployment, should_start: should_start)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ArgumentError, RuntimeAgent::Failure => error
    Result.failure(error)
  end

  def deploy_git(app, repository_url:, git_ref:, requested_by:, start: false, builder: GitDeploymentBuilder.new)
    build_result = builder.build(app, repository_url: repository_url, git_ref: git_ref)
    return Result.failure(StandardError.new(build_result.error)) unless build_result.success?

    should_start = start || app.status == "running"
    stop_running_app(app) if app.status == "running"

    deployment = nil
    app.deployments.transaction do
      app.update!(
        image_reference: build_result.image_reference,
        internal_port: app.internal_port,
        health_check_kind: app.health_check_kind,
        health_check_path: app.health_check_path
      )
      deployment = create_current_deployment(
        app,
        image_reference: build_result.image_reference,
        source_type: "git",
        git_repository_url: repository_url,
        git_ref: git_ref.presence || "main",
        build_status: "succeeded",
        build_logs: build_result.logs
      )
      app.record_event!(
        "deployment.git_built",
        "Git deployment #{deployment.id} was built and became current",
        metadata: deployment_metadata(deployment).merge(
          requested_by: requested_by,
          git_repository_url: deployment.git_repository_url,
          git_ref: deployment.git_ref
        )
      )
    end

    start_or_sleep(app, deployment, should_start: should_start)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ArgumentError, RuntimeAgent::Failure => error
    Result.failure(error)
  end

  def rollback(app, deployment:, requested_by:)
    should_restart = app.status == "running"
    stop_running_app(app) if should_restart

    app.deployments.transaction do
      app.update!(
        image_reference: deployment.image_reference,
        internal_port: deployment.port,
        health_check_kind: deployment.health_check_kind,
        health_check_path: deployment.health_check_path
      )
      deployment.mark_current!
      deployment.update!(status: "deployed")
      app.record_event!(
        "deployment.rollback",
        "Rolled back to deployment #{deployment.id}",
        metadata: deployment_metadata(deployment).merge(requested_by: requested_by)
      )
    end

    start_or_sleep(app, deployment, should_start: should_restart)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ArgumentError, RuntimeAgent::Failure => error
    Result.failure(error)
  end

  private

  attr_reader :runtime_agent

  def create_current_deployment(app, image_reference:, **attributes)
    app.deployments.where(current: true).find_each { |deployment| deployment.update!(current: false, status: "retired") }
    app.deployments.create!(
      image_reference: image_reference,
      port: app.internal_port,
      health_check_kind: app.health_check_kind,
      health_check_path: app.health_check_path,
      status: "deployed",
      current: true,
      deployed_at: Time.current,
      env_snapshot: app.runtime_environment,
      **attributes
    )
  end

  def stop_running_app(app)
    result = runtime_agent.stop_app(app)
    raise RuntimeAgent::Failure.new(result.error) unless result.success?
  end

  def start_or_sleep(app, deployment, should_start:)
    if should_start
      deployment.update!(status: "deploying")
      result = runtime_agent.start_app(app.reload)
      if result.success?
        deployment.update!(status: "deployed", deployed_at: Time.current)
        Result.success(deployment)
      else
        deployment.update!(status: "failed")
        Result.failure(result.error)
      end
    else
      app.reload.manual_override_to!("sleeping", reason: "deployment prepared without runtime start")
      Result.success(deployment)
    end
  end

  def deployment_metadata(deployment)
    {
      deployment_id: deployment.id,
      image_reference: deployment.image_reference,
      port: deployment.port,
      health_check_kind: deployment.health_check_kind,
      health_check_path: deployment.health_check_path
    }.compact
  end

  def validation_failure(message)
    deployment = Deployment.new
    deployment.errors.add(:image_reference, message)
    Result.failure(ActiveModel::ValidationError.new(deployment))
  end
end

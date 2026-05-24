class AppsController < ApplicationController
  before_action :set_app, only: %i[
    show edit update deploy deploy_git rollback wake sleep inspect_runtime provision_database rotate_database_credentials
    backup_database custom_domains verify_domain provision_domain_tls
  ]
  before_action :require_app_manager, only: %i[
    edit update deploy deploy_git rollback wake sleep inspect_runtime provision_database rotate_database_credentials
    backup_database custom_domains verify_domain provision_domain_tls
  ]

  def index
    @apps = current_user.accessible_apps.includes(:routes, :deployments, :runtime_instances).order(:name)
  end

  def show
    load_app_detail
  end

  def new
    @app = current_user.apps.new(sample_app? ? App::SAMPLE_APP_ATTRIBUTES : {})
    load_form_collections
  end

  def edit
    @environment_variables = @app.environment_variables.ordered
    load_form_collections
  end

  def create
    @app = current_user.apps.new(app_params)

    if @app.save
      create_initial_deployment(@app)
      redirect_to @app, notice: "App created."
    else
      load_form_collections
      render :new, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotFound
    @app = current_user.apps.new(raw_app_params.except(:team_id))
    @app.errors.add(:team, "is not available")
    load_form_collections
    render :new, status: :unprocessable_content
  end

  def update
    previous_deployment_config = deployment_config_for(@app)

    if @app.update(app_params)
      sync_volume_from_params(@app)
      sync_database_from_params(@app)
      create_replacement_deployment(@app) if deployment_config_changed?(previous_deployment_config, @app)
      @app.record_event!("app.updated", "#{@app.name} settings were updated", metadata: changed_settings_metadata)
      redirect_to @app, notice: "App settings updated."
    else
      @environment_variables = @app.environment_variables.ordered
      load_form_collections
      render :edit, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotFound
    @environment_variables = @app.environment_variables.ordered
    @app.errors.add(:team, "is not available")
    load_form_collections
    render :edit, status: :unprocessable_content
  end

  def deploy
    result = deployment_workflow.deploy_image(
      @app,
      image_reference: deployment_params.fetch(:image_reference),
      start: ActiveModel::Type::Boolean.new.cast(deployment_params[:start]),
      requested_by: current_user.email
    )
    return redirect_to @app, notice: deployment_notice(result.deployment) if result.success?

    redirect_to @app, alert: result.error.message
  end

  def deploy_git
    result = deployment_workflow.deploy_git(
      @app,
      repository_url: git_deployment_params.fetch(:git_repository_url),
      git_ref: git_deployment_params[:git_ref],
      start: ActiveModel::Type::Boolean.new.cast(git_deployment_params[:start]),
      requested_by: current_user.email
    )
    return redirect_to @app, notice: deployment_notice(result.deployment) if result.success?

    redirect_to @app, alert: result.error.message
  end

  def rollback
    deployment = @app.deployments.find(params.expect(:deployment_id))
    result = deployment_workflow.rollback(@app, deployment: deployment, requested_by: current_user.email)
    return redirect_to @app, notice: "Rolled back to deployment #{deployment.id}." if result.success?

    redirect_to @app, alert: result.error.message
  end

  def wake
    result = runtime_agent.start_app(@app)
    return redirect_to @app, notice: "Wake requested." if result.success?

    redirect_to @app, alert: result.error.message
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to @app, alert: error.message
  end

  def sleep
    result = AppSleeper.new(runtime_agent: runtime_agent).sleep(
      @app,
      requested_by: current_user.email,
      trigger: "manual_dashboard",
      force: true
    )
    return redirect_to @app, notice: "Sleep requested." if result.success?

    redirect_to @app, alert: result.error.message
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to @app, alert: error.message
  end

  def inspect_runtime
    result = runtime_agent.inspect_app(@app)
    return redirect_to @app, notice: "Runtime inspected." if result.success?

    redirect_to @app, alert: result.error.message
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to @app, alert: error.message
  end

  def provision_database
    database_resource = @app.ensure_database_resource!
    result = DatabaseResourceProvisioner.new.provision(database_resource)
    return redirect_to @app, notice: result.message if result.success?

    redirect_to @app, alert: result.message
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to @app, alert: error.message
  end

  def rotate_database_credentials
    database_resource = @app.ensure_database_resource!
    database_resource.rotate_credentials!
    redirect_to @app, notice: "Database credentials rotated."
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to @app, alert: error.message
  end

  def backup_database
    database_resource = @app.database_resource
    return redirect_to @app, alert: "App has no database resource." unless database_resource

    result = DatabaseBackupExporter.new.export(database_resource)
    return redirect_to @app, notice: result.message if result.success?

    redirect_to @app, alert: result.message
  end

  def custom_domains
    route = @app.routes.create!(
      hostname: custom_domain_params.fetch(:hostname),
      route_type: "custom_domain",
      active: false
    )
    @app.record_event!(
      "domain.created",
      "Custom domain #{route.hostname} was added",
      metadata: route.public_status
    )
    redirect_to @app, notice: "Custom domain added. Add the TXT record before verifying ownership."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to @app, alert: error.record.errors.full_messages.to_sentence
  end

  def verify_domain
    route = @app.routes.custom_domains.find(domain_action_params.fetch(:route_id))
    if route.verify_ownership!(domain_action_params[:ownership_token])
      redirect_to @app, notice: "Domain ownership verified."
    else
      redirect_to @app, alert: "Domain ownership token did not match."
    end
  end

  def provision_domain_tls
    route = @app.routes.custom_domains.find(domain_action_params.fetch(:route_id))
    route.provision_tls!
    redirect_to @app, notice: "TLS is active for #{route.hostname}."
  rescue ArgumentError => error
    redirect_to @app, alert: error.message
  end

  private

  def set_app
    scope = current_user.admin? ? App.all : current_user.accessible_apps
    @app = scope.find(params.expect(:id))
  end

  def require_app_manager
    return if current_user.can_manage_app?(@app)

    head :not_found
  end

  def app_params
    permitted = raw_app_params
    if permitted.key?(:team_id)
      team_id = permitted[:team_id].presence
      permitted[:team_id] = team_id.present? ? assignable_teams.find(team_id).id : nil
    end
    permitted
  end

  def raw_app_params
    params.expect(app: %i[
      name
      slug
      image_reference
      internal_port
      health_check_kind
      health_check_path
      idle_timeout_seconds
      sleep_mode
      team_id
      startup_timeout_seconds
      memory_limit_bytes
      cpu_limit
      volume_enabled
      volume_mount_path
      database_enabled
      database_type
    ])
  end

  def assignable_teams
    return Team.order(:name) if current_user.admin?

    Team.joins(:team_memberships)
        .where(team_memberships: { user_id: current_user.id, role: TeamMembership::WRITE_ROLES })
        .order(:name)
  end

  def load_form_collections
    @assignable_teams = assignable_teams
  end

  def deployment_params
    params.expect(deployment: %i[image_reference start])
  end

  def git_deployment_params
    params.expect(deployment: %i[git_repository_url git_ref start])
  end

  def custom_domain_params
    params.expect(route: %i[hostname])
  end

  def domain_action_params
    params.permit(:route_id, :ownership_token)
  end

  def create_initial_deployment(app)
    return if app.image_reference.blank? || app.internal_port.blank?

    app.deployments.create!(
      image_reference: app.image_reference,
      port: app.internal_port,
      health_check_kind: app.health_check_kind,
      health_check_path: app.health_check_path,
      status: "created",
      current: true
    )
  end

  def create_replacement_deployment(app)
    app.deployments.transaction do
      app.deployments.where(current: true).update_all(current: false, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      app.deployments.create!(
        image_reference: app.image_reference,
        port: app.internal_port,
        health_check_kind: app.health_check_kind,
        health_check_path: app.health_check_path,
        status: "created",
        current: true
      )
    end
  end

  def deployment_config_for(app)
    {
      image_reference: app.image_reference,
      internal_port: app.internal_port,
      health_check_kind: app.health_check_kind,
      health_check_path: app.health_check_path
    }
  end

  def deployment_config_changed?(previous_config, app)
    previous_config != deployment_config_for(app) && app.image_reference.present? && app.internal_port.present?
  end

  def changed_settings_metadata
    @app.previous_changes.except("updated_at").transform_values(&:last)
  end

  def load_app_detail
    @events = @app.app_events.order(created_at: :desc).limit(20)
    @deployments = @app.deployments.order(created_at: :desc)
    @runtime_instance = @app.runtime_instances.order(created_at: :desc).first
    @latest_logs = @app.app_logs.includes(:runtime_instance, :deployment).recent(20)
    @routes = @app.routes.order(active: :desc, hostname: :asc)
    @environment_variables = @app.environment_variables.ordered
    @database_backups = @app.database_resource&.database_backups&.recent || DatabaseBackup.none
    @request_metrics = @app.app_request_metrics.recent(5)
    @runtime_metrics = @app.runtime_metric_snapshots.recent(5)
    @cold_start_metrics = @app.cold_start_metrics.recent(5)
  end

  def sync_volume_from_params(app)
    if app.volume_requested?
      app.ensure_volume!(mount_path: app.volume_mount_path)
      app.record_event!(
        "volume.created",
        "Persistent volume was configured for #{app.name}",
        metadata: app.volume.metadata
      )
    elsif app.volume&.active?
      app.volume.update!(status: "disabled")
      app.record_event!(
        "volume.disabled",
        "Persistent volume was disabled for #{app.name}",
        metadata: app.volume.metadata
      )
    end
  end

  def sync_database_from_params(app)
    if app.database_requested?
      app.ensure_database_resource!(database_type: app.database_type)
      app.record_event!(
        "database.created",
        "Shared database resource was configured for #{app.name}",
        metadata: app.database_resource.public_metadata
      )
    elsif app.database_resource.present? && app.database_resource.status != "disabled"
      app.database_resource.update!(status: "disabled")
      app.record_event!(
        "database.disabled",
        "Shared database resource was disabled for #{app.name}",
        metadata: app.database_resource.public_metadata
      )
    end
  end

  def runtime_agent
    RuntimeAgent.build
  end

  def deployment_workflow
    DeploymentWorkflow.new(runtime_agent: runtime_agent)
  end

  def sample_app?
    ActiveModel::Type::Boolean.new.cast(params[:sample])
  end

  def deployment_notice(deployment)
    "Deployment #{deployment.id} is current."
  end
end

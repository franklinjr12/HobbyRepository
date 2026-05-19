class AppsController < ApplicationController
  before_action :set_app, only: %i[show edit update wake sleep inspect_runtime]

  def index
    @apps = current_user.apps.includes(:routes, :deployments, :runtime_instances).order(:name)
  end

  def show
    load_app_detail
  end

  def new
    @app = current_user.apps.new
  end

  def edit
    @environment_variables = @app.environment_variables.ordered
  end

  def create
    @app = current_user.apps.new(app_params)

    if @app.save
      create_initial_deployment(@app)
      redirect_to @app, notice: "App created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    previous_deployment_config = deployment_config_for(@app)

    if @app.update(app_params)
      create_replacement_deployment(@app) if deployment_config_changed?(previous_deployment_config, @app)
      @app.record_event!("app.updated", "#{@app.name} settings were updated", metadata: changed_settings_metadata)
      redirect_to @app, notice: "App settings updated."
    else
      @environment_variables = @app.environment_variables.ordered
      render :edit, status: :unprocessable_content
    end
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

  private

  def set_app
    @app = current_user.apps.find(params.expect(:id))
  end

  def app_params
    params.expect(app: %i[
      name
      slug
      image_reference
      internal_port
      health_check_kind
      health_check_path
      idle_timeout_seconds
      startup_timeout_seconds
      memory_limit_bytes
      cpu_limit
    ])
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
    @runtime_instance = @app.runtime_instances.order(created_at: :desc).first
    @routes = @app.routes.order(active: :desc, hostname: :asc)
    @environment_variables = @app.environment_variables.ordered
  end

  def runtime_agent
    RuntimeAgent.build
  end
end

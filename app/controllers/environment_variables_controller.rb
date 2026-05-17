class EnvironmentVariablesController < ApplicationController
  before_action :set_app
  before_action :set_environment_variable, only: %i[update destroy]

  def create
    @environment_variable = @app.environment_variables.new(environment_variable_params)

    if @environment_variable.save
      record_environment_event!("environment_variable.created", @environment_variable)
      redirect_to edit_app_path(@app), notice: "Environment variable added."
    else
      render_app_settings(:unprocessable_content)
    end
  end

  def update
    if @environment_variable.update(environment_variable_params)
      record_environment_event!("environment_variable.updated", @environment_variable)
      redirect_to edit_app_path(@app), notice: "Environment variable updated."
    else
      render_app_settings(:unprocessable_content)
    end
  end

  def destroy
    metadata = @environment_variable.metadata
    @environment_variable.destroy!
    @app.record_event!("environment_variable.deleted", "Environment variable #{metadata[:key]} was deleted", metadata: metadata)

    redirect_to edit_app_path(@app), notice: "Environment variable deleted."
  end

  private

  def set_app
    @app = current_user.apps.find(params.expect(:app_id))
  end

  def set_environment_variable
    @environment_variable = @app.environment_variables.find(params.expect(:id))
  end

  def environment_variable_params
    params.expect(environment_variable: %i[key value secret])
  end

  def render_app_settings(status)
    @environment_variables = @app.environment_variables.ordered
    render "apps/edit", status: status
  end

  def record_environment_event!(event_type, environment_variable)
    @app.record_event!(
      event_type,
      "Environment variable #{environment_variable.key} was saved",
      metadata: environment_variable.metadata
    )
  end
end

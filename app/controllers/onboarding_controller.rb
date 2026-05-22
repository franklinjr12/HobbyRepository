class OnboardingController < ApplicationController
  def show
    @sample_app = current_user.apps.find_by(slug: sample_slug)
  end

  def create_sample_app
    @app = current_user.apps.find_or_initialize_by(slug: sample_slug)
    @app.assign_attributes(App::SAMPLE_APP_ATTRIBUTES.merge(slug: sample_slug)) if @app.new_record?

    if @app.save
      create_initial_deployment(@app) if @app.current_deployment.blank?
      redirect_to @app, notice: "Sample app is ready to deploy."
    else
      redirect_to onboarding_path, alert: @app.errors.full_messages.to_sentence
    end
  end

  private

  def sample_slug
    "sample-whoami-app"
  end

  def create_initial_deployment(app)
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

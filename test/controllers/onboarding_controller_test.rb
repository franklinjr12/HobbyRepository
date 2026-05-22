require "test_helper"

class OnboardingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "onboarding@example.com", password: "password123")
    Node.ensure_local!
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  test "show explains first app deployment requirements" do
    get onboarding_path

    assert_response :success
    assert_select "h1", text: "First app guide"
    assert_select "code", text: "traefik/whoami:v1.10"
    assert_select "dt", text: "Internal port"
    assert_select "li", text: /persistent volume/
    assert_select "li", text: /idle timeout/
    assert_select "a[href='#{new_app_path(sample: true)}']", text: "Prefill form"
    assert_select "form[action='#{create_sample_app_onboarding_path}']"
  end

  test "creates sample app with current deployment" do
    assert_difference -> { App.count }, 1 do
      assert_difference -> { Deployment.count }, 1 do
        post create_sample_app_onboarding_path
      end
    end

    app = @user.apps.find_by!(slug: "sample-whoami-app")
    assert_redirected_to app_path(app)
    assert_equal "Sample Whoami App", app.name
    assert_equal "traefik/whoami:v1.10", app.image_reference
    assert_equal 80, app.internal_port
    assert_equal 300, app.idle_timeout_seconds
    assert_equal "traefik/whoami:v1.10", app.current_deployment.image_reference
    assert_equal 80, app.current_deployment.port
  end

  test "reuses existing sample app instead of duplicating it" do
    existing_app = @user.apps.create!(
      name: "Sample Whoami App",
      slug: "sample-whoami-app",
      image_reference: "traefik/whoami:v1.10",
      internal_port: 80
    )
    existing_app.deployments.create!(image_reference: "traefik/whoami:v1.10", port: 80, current: true)

    assert_no_difference -> { App.count } do
      assert_no_difference -> { Deployment.count } do
        post create_sample_app_onboarding_path
      end
    end

    assert_redirected_to app_path(existing_app)
  end

  test "show includes wake and sleep actions after sample app exists" do
    app = @user.apps.create!(
      name: "Sample Whoami App",
      slug: "sample-whoami-app",
      image_reference: "traefik/whoami:v1.10",
      internal_port: 80
    )

    get onboarding_path

    assert_response :success
    assert_select "a[href='#{app_path(app)}']", text: "Open sample"
    assert_select "form[action='#{wake_app_path(app)}']"
    assert_select "form[action='#{sleep_app_path(app)}']"
  end
end

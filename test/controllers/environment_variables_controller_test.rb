require "test_helper"

class EnvironmentVariablesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "env-controller@example.com", password: "password123")
    @hosted_app = @user.apps.create!(name: "Env Controller")
    post "/sign_in", params: { email: @user.email, password: "password123" }
  end

  test "creates environment variable and records event without value" do
    assert_difference -> { @hosted_app.environment_variables.count }, 1 do
      post app_environment_variables_path(@hosted_app), params: {
        environment_variable: {
          key: "api_token",
          value: "raw-secret",
          secret: "1"
        }
      }
    end

    environment_variable = @hosted_app.environment_variables.find_by!(key: "API_TOKEN")
    event = @hosted_app.app_events.order(:created_at).last

    assert_redirected_to edit_app_path(@hosted_app)
    assert environment_variable.secret?
    assert_equal "raw-secret", environment_variable.value
    assert_equal "environment_variable.created", event.event_type
    assert_equal({ "key" => "API_TOKEN", "secret" => true }, event.metadata)
    assert_no_match "raw-secret", event.metadata.to_json
  end

  test "rejects invalid environment variable key" do
    post app_environment_variables_path(@hosted_app), params: {
      environment_variable: {
        key: "bad-key",
        value: "value"
      }
    }

    assert_response :unprocessable_content
    assert_select ".error-panel", text: /Key must start/
  end

  test "updates environment variable with replacement secret value" do
    environment_variable = @hosted_app.environment_variables.create!(key: "API_TOKEN", value: "old-secret", secret: true)

    patch app_environment_variable_path(@hosted_app, environment_variable), params: {
      environment_variable: {
        value: "new-secret",
        secret: "1"
      }
    }

    assert_redirected_to edit_app_path(@hosted_app)
    assert_equal "new-secret", environment_variable.reload.value
    assert_equal "environment_variable.updated", @hosted_app.app_events.order(:created_at).last.event_type
  end

  test "deletes environment variable" do
    environment_variable = @hosted_app.environment_variables.create!(key: "API_TOKEN", value: "secret", secret: true)

    assert_difference -> { @hosted_app.environment_variables.count }, -1 do
      delete app_environment_variable_path(@hosted_app, environment_variable)
    end

    assert_redirected_to edit_app_path(@hosted_app)
    assert_equal "environment_variable.deleted", @hosted_app.app_events.order(:created_at).last.event_type
  end

  test "does not manage another user's environment variables" do
    other_user = User.create!(email: "env-other@example.com", password: "password123")
    other_app = other_user.apps.create!(name: "Other Env App")

    post app_environment_variables_path(other_app), params: {
      environment_variable: {
        key: "TOKEN",
        value: "secret"
      }
    }

    assert_response :not_found
    assert_empty other_app.environment_variables.reload
  end
end

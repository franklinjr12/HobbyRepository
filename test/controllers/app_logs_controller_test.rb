require "test_helper"

class AppLogsControllerTest < ActionDispatch::IntegrationTest
  class FakeRuntimeAgent
    def initialize(result)
      @result = result
    end

    def get_logs(app)
      app.app_logs.create!(
        runtime_instance: app.runtime_instances.last,
        deployment: app.current_deployment,
        stream: "stdout",
        logged_at: Time.current,
        message: "fresh runtime line"
      )
      @result
    end
  end

  setup do
    @user = User.create!(email: "app-logs@example.com", password: "password123")
    @other_user = User.create!(email: "other-app-logs@example.com", password: "password123")
    Node.ensure_local!
    post sign_in_path, params: { email: @user.email, password: "password123" }

    @app = @user.apps.create!(name: "Logged App", image_reference: "example/logged:latest", internal_port: 3000)
    @deployment = @app.deployments.create!(image_reference: "example/logged:latest", port: 3000, current: true)
    @runtime_instance = @app.runtime_instances.create!(
      status: "running",
      container_id: "logged-container",
      deployment: @deployment
    )
    @app.app_logs.create!(
      runtime_instance: @runtime_instance,
      deployment: @deployment,
      stream: "stderr",
      logged_at: 1.minute.ago,
      message: "startup failed"
    )
    @app.app_logs.create!(
      runtime_instance: @runtime_instance,
      deployment: @deployment,
      stream: "stdout",
      logged_at: 2.minutes.ago,
      message: "listening on port 3000"
    )
  end

  test "index shows readable app logs with filters and auto refresh" do
    get app_app_logs_path(@app), params: { q: "startup", auto_refresh: "1" }

    assert_response :success
    assert_select "meta[http-equiv='refresh'][content='5']"
    assert_select ".log-entry-stderr code", text: "startup failed"
    assert_select ".log-entry code", text: /listening/, count: 0
    assert_select "form[action='#{collect_app_app_logs_path(@app)}']"
  end

  test "collect refreshes runtime logs" do
    result = RuntimeAgent::Result.success(command: "get_logs")

    with_runtime_agent(FakeRuntimeAgent.new(result)) do
      assert_difference -> { @app.app_logs.count }, 1 do
        post collect_app_app_logs_path(@app)
      end
    end

    assert_redirected_to app_app_logs_path(@app)
    assert_equal "Logs refreshed.", flash[:notice]
  end

  test "does not show another user's app logs" do
    private_app = @other_user.apps.create!(name: "Private Logs", slug: "private-logs")

    get app_app_logs_path(private_app)

    assert_response :not_found
  end

  private

  def with_runtime_agent(agent)
    original = RuntimeAgent.method(:build)
    RuntimeAgent.define_singleton_method(:build) { agent }
    yield
  ensure
    RuntimeAgent.define_singleton_method(:build) { original.call }
  end
end

require "test_helper"

class WakeAppJobTest < ActiveJob::TestCase
  class FakeRuntimeAgent
    attr_reader :started_app_ids

    def initialize
      @started_app_ids = []
    end

    def start_app(app)
      @started_app_ids << app.id
      app.manual_override_to!("running", reason: "test wake completed")
      RuntimeAgent::Result.success(command: "start_app")
    end
  end

  setup do
    @node = Node.create!(name: "Local", hostname: "local.test", local: true)
    @owner = User.create!(email: "wake-job@example.com", password: "password123")
    @app = App.create!(name: "Wake Job App", owner: @owner, node: @node, status: "sleeping")
    @app.manual_override_to!("waking", reason: "test wake request")
  end

  test "starts only when app is still waking" do
    agent = FakeRuntimeAgent.new

    with_runtime_agent(agent) do
      WakeAppJob.perform_now(@app.id)
      WakeAppJob.perform_now(@app.id)
    end

    assert_equal [ @app.id ], agent.started_app_ids
    assert_equal "running", @app.reload.status
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

require "test_helper"

class RuntimeCapacityGuardTest < ActiveSupport::TestCase
  setup do
    @node = Node.create!(
      name: "Capacity Node",
      hostname: "capacity.test",
      local: true,
      capacity_memory_bytes: 512.megabytes,
      capacity_cpu: 1.0
    )
    @owner = User.create!(email: "capacity@example.com", password: "password123")
  end

  test "allows start when running count and reservations fit" do
    running_app(memory_limit_bytes: 128.megabytes, cpu_limit: 0.25)
    app = pending_app(memory_limit_bytes: 128.megabytes, cpu_limit: 0.25)

    result = RuntimeCapacityGuard.new(node: @node, max_running_apps: 3).check(app)

    assert result.success?
    assert_equal 1, result.details.fetch(:running_app_count)
    assert_equal 128.megabytes, result.details.fetch(:reserved_memory_bytes)
  end

  test "rejects start when running app count is exhausted" do
    running_app(memory_limit_bytes: 128.megabytes)
    app = pending_app(memory_limit_bytes: 128.megabytes)

    result = RuntimeCapacityGuard.new(node: @node, max_running_apps: 1).check(app)

    assert_not result.success?
    assert_match "Host capacity unavailable", result.error
  end

  test "rejects start when memory reservations exceed node capacity" do
    running_app(memory_limit_bytes: 384.megabytes)
    app = pending_app(memory_limit_bytes: 256.megabytes)

    result = RuntimeCapacityGuard.new(node: @node, max_running_apps: 10).check(app)

    assert_not result.success?
    assert_match "memory reservations", result.error
  end

  test "rejects start when cpu reservations exceed node capacity" do
    running_app(memory_limit_bytes: 128.megabytes, cpu_limit: 0.75)
    app = pending_app(memory_limit_bytes: 128.megabytes, cpu_limit: 0.5)

    result = RuntimeCapacityGuard.new(node: @node, max_running_apps: 10).check(app)

    assert_not result.success?
    assert_match "CPU reservations", result.error
  end

  private

  def running_app(memory_limit_bytes:, cpu_limit: nil)
    pending_app(memory_limit_bytes: memory_limit_bytes, cpu_limit: cpu_limit).tap do |app|
      app.manual_override_to!("running", reason: "test running reservation")
    end
  end

  def pending_app(memory_limit_bytes:, cpu_limit: nil)
    @owner.apps.create!(
      name: "Capacity App #{SecureRandom.hex(4)}",
      node: @node,
      memory_limit_bytes: memory_limit_bytes,
      cpu_limit: cpu_limit,
      status: "sleeping"
    )
  end
end

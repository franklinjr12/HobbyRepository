require "test_helper"

class RuntimeInstanceTest < ActiveSupport::TestCase
  test "inherits node placement from app" do
    node = Node.create!(name: "Local", hostname: "local.test", local: true)
    app = App.create!(name: "Placed", slug: "placed", node: node)

    runtime_instance = RuntimeInstance.create!(app: app, status: "starting")

    assert_equal node, runtime_instance.node
  end
end

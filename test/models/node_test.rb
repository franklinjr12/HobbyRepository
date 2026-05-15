require "test_helper"

class NodeTest < ActiveSupport::TestCase
  test "ensure local node is idempotent" do
    first = Node.ensure_local!
    second = Node.ensure_local!

    assert_equal first, second
    assert first.local?
    assert_equal "active", first.status
  end

  test "only one local node is valid" do
    Node.create!(name: "Local", hostname: "local.test", local: true)
    other = Node.new(name: "Other", hostname: "other.test", local: true)

    assert_not other.valid?
    assert_includes other.errors[:local], "has already been taken"
  end
end

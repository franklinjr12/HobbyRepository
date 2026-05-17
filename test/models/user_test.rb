require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "normalizes email and authenticates" do
    user = User.create!(email: " Admin@Example.COM ", password: "password123")

    assert_equal "admin@example.com", user.email
    assert user.authenticate("password123")
  end

  test "requires unique email" do
    User.create!(email: "admin@example.com", password: "password123")
    duplicate = User.new(email: "ADMIN@example.com", password: "password123")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end
end

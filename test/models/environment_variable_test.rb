require "test_helper"

class EnvironmentVariableTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "env-model@example.com", password: "password123")
    @app = @owner.apps.create!(name: "Env Model")
  end

  test "normalizes and validates keys" do
    environment_variable = @app.environment_variables.create!(key: "database_url", value: "postgres://example")

    assert_equal "DATABASE_URL", environment_variable.key
  end

  test "rejects invalid keys" do
    environment_variable = @app.environment_variables.new(key: "1-bad", value: "value")

    assert_not environment_variable.valid?
    assert_includes environment_variable.errors[:key],
                    "must start with a letter or underscore and use only uppercase letters, numbers, and underscores"
  end

  test "requires unique keys per app" do
    @app.environment_variables.create!(key: "TOKEN", value: "one")
    duplicate = @app.environment_variables.new(key: "TOKEN", value: "two")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
  end

  test "masks secret display values but keeps runtime value available" do
    environment_variable = @app.environment_variables.create!(key: "TOKEN", value: "raw-token", secret: true)

    assert_equal "********", environment_variable.display_value
    assert_equal [ "TOKEN", "raw-token" ], environment_variable.runtime_pair
  end
end

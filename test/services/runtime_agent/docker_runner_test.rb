require "test_helper"

module RuntimeAgent
  class DockerRunnerTest < ActiveSupport::TestCase
    test "normalizes missing executables into failed command results" do
      result = DockerRunner.new.call([ "definitely-missing-docker-command" ])

      assert_not result.success?
      assert_equal 127, result.exit_status
      assert_match "No such file", result.stderr
    end
  end
end

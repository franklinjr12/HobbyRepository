require "test_helper"

class ApplicationJobTest < ActiveJob::TestCase
  class ProbeJob < ApplicationJob
    def perform
    end
  end

  test "active job test adapter can enqueue jobs" do
    assert_enqueued_jobs 1 do
      ProbeJob.perform_later
    end
  end
end

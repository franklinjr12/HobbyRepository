require "test_helper"

class AppEventTest < ActiveSupport::TestCase
  test "requires event type and message" do
    event = AppEvent.new

    assert_not event.valid?
    assert_includes event.errors[:event_type], "can't be blank"
    assert_includes event.errors[:message], "can't be blank"
  end
end

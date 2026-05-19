require "test_helper"

class VolumeTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "volume-model@example.com", password: "password123")
    @app = @owner.apps.create!(name: "Volume Model")
  end

  test "generates a platform host path and prepares the directory" do
    volume = @app.create_volume!(mount_path: "/data")

    assert_equal "active", volume.status
    assert_equal "/data", volume.mount_path
    assert_match %r{/storage/app_volumes/app-#{@app.id}-volume-model\z}, volume.host_path.tr("\\", "/")
    assert Dir.exist?(volume.host_path)
  end

  test "validates mount path as an absolute container path" do
    volume = @app.build_volume(mount_path: "data")

    assert_not volume.valid?
    assert_includes volume.errors[:mount_path], "must start with /"
  end

  test "rejects root mount path" do
    volume = @app.build_volume(mount_path: "/")

    assert_not volume.valid?
    assert_includes volume.errors[:mount_path], "cannot be the container root"
  end
end

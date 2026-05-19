require "fileutils"

class Volume < ApplicationRecord
  STATUSES = %w[active disabled failed].freeze
  DEFAULT_MOUNT_PATH = "/data".freeze
  DEFAULT_DIRECTORY_MODE = 0o750

  belongs_to :app

  before_validation :assign_defaults
  before_create :ensure_host_directory!

  validates :mount_path, :host_path, :status, presence: true
  validates :host_path, uniqueness: true
  validates :app_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :size_limit_bytes, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :mount_path_must_be_absolute_container_path

  scope :active, -> { where(status: "active") }

  def self.storage_root
    Pathname(ENV.fetch("HOBBY_VOLUME_ROOT", Rails.root.join("storage/app_volumes").to_s)).cleanpath
  end

  def self.host_path_for(app)
    storage_root.join("app-#{app.id}-#{app.slug}").to_s
  end

  def active?
    status == "active"
  end

  def ensure_host_directory!
    FileUtils.mkdir_p(host_path, mode: DEFAULT_DIRECTORY_MODE)
    FileUtils.chmod(DEFAULT_DIRECTORY_MODE, host_path)
  rescue SystemCallError => error
    self.status = "failed"
    errors.add(:host_path, "could not be prepared: #{error.message}")
    raise ActiveRecord::RecordInvalid, self
  end

  def runtime_mount
    [ host_path, mount_path ].join(":")
  end

  def metadata
    {
      volume_id: id,
      mount_path: mount_path,
      host_path: host_path,
      size_limit_bytes: size_limit_bytes,
      status: status
    }.compact
  end

  private

  def assign_defaults
    self.mount_path = mount_path.to_s.strip if mount_path.present?
    self.mount_path = DEFAULT_MOUNT_PATH if mount_path.blank?
    self.status = "active" if status.blank?
    self.host_path = self.class.host_path_for(app) if host_path.blank? && app&.persisted?
  end

  def mount_path_must_be_absolute_container_path
    return if mount_path.blank?

    unless mount_path.start_with?("/")
      errors.add(:mount_path, "must start with /")
    end

    if mount_path == "/"
      errors.add(:mount_path, "cannot be the container root")
    end

    if mount_path.include?("\0") || mount_path.include?("\n") || mount_path.include?("\r") || mount_path.include?(":")
      errors.add(:mount_path, "contains unsupported characters")
    end
  end
end

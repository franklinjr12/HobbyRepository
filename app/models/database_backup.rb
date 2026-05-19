class DatabaseBackup < ApplicationRecord
  MASK = "********".freeze
  STATUSES = %w[pending completed failed].freeze

  belongs_to :database_resource

  before_validation :assign_default_filename

  validates :filename, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def completed?
    status == "completed"
  end

  def content
    return if encrypted_content.blank?

    DatabaseResource.decrypt(encrypted_content)
  end

  def content=(raw_content)
    self.encrypted_content = DatabaseResource.encrypt(raw_content)
  end

  def mark_completed!(raw_content)
    self.content = raw_content
    update!(status: "completed", completed_at: Time.current, failure_message: nil)
  end

  def mark_failed!(message)
    update!(status: "failed", failure_message: message)
  end

  def public_metadata
    {
      database_backup_id: id,
      database_resource_id: database_resource_id,
      status: status,
      filename: filename,
      completed_at: completed_at&.iso8601
    }.compact
  end

  private

  def assign_default_filename
    return if filename.present? || database_resource.blank?

    timestamp = Time.current.utc.strftime("%Y%m%d%H%M%S")
    self.filename = "#{database_resource.database_name}-#{timestamp}.sql"
  end
end

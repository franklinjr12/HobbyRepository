class Deployment < ApplicationRecord
  STATUSES = %w[created deploying deployed failed retired].freeze
  SOURCE_TYPES = %w[image git].freeze
  BUILD_STATUSES = %w[pending running succeeded failed].freeze
  IMAGE_REFERENCE_FORMAT = /\A[a-z0-9]+(?:(?:[._-]|__|[-]*)[a-z0-9]+)*(?::[0-9]+)?(?:\/[a-z0-9]+(?:(?:[._-]|__|[-]*)[a-z0-9]+)*)*(?::[\w][\w.-]{0,127})?(?:@sha256:[a-f0-9]{64})?\z/.freeze

  belongs_to :app
  has_many :runtime_instances, dependent: :restrict_with_error
  has_many :app_logs, dependent: :nullify

  before_validation :copy_defaults_from_app
  after_create :record_creation_event

  validates :image_reference, :port, :status, presence: true
  validates :image_reference, format: {
    with: IMAGE_REFERENCE_FORMAT,
    message: "must be a valid container image reference"
  }, allow_blank: true
  validates :status, inclusion: { in: STATUSES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :build_status, inclusion: { in: BUILD_STATUSES }, allow_blank: true
  validates :git_repository_url, presence: true, if: :git_source?
  validates :git_ref, presence: true, if: :git_source?
  validates :health_check_kind, inclusion: { in: App::HEALTH_CHECK_KINDS }
  validates :health_check_path, presence: true, if: :http_health_check?
  validates :health_check_path, format: { with: %r{\A/[^\r\n]*\z}, message: "must start with /" },
                                allow_blank: true
  validates :port, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 }

  def mark_current!
    transaction do
      app.deployments.where.not(id: id).find_each { |deployment| deployment.update!(current: false) }
      update!(current: true, deployed_at: deployed_at || Time.current)
    end
  end

  def self.valid_image_reference?(image_reference)
    image_reference.to_s.match?(IMAGE_REFERENCE_FORMAT)
  end

  def log_label
    "Deployment ##{id} - #{image_reference}"
  end

  def git_source?
    source_type == "git"
  end

  private

  def http_health_check?
    health_check_kind == "http"
  end

  def copy_defaults_from_app
    return unless app

    self.image_reference = app.image_reference if image_reference.blank?
    self.port ||= app.internal_port
    self.health_check_kind = app.health_check_kind if health_check_kind.blank? || health_check_kind == App::DEFAULT_HEALTH_CHECK_KIND
    self.health_check_path = app.health_check_path if health_check_path.blank? && http_health_check?
    self.health_check_path = nil unless http_health_check?
  end

  def record_creation_event
    app.record_event!(
      "deployment.created",
      "Deployment #{id} was created",
      metadata: {
        deployment_id: id,
        image_reference: image_reference,
        port: port,
        health_check_kind: health_check_kind,
        health_check_path: health_check_path,
        current: current
      }
    )
  end
end

class Deployment < ApplicationRecord
  STATUSES = %w[created deploying deployed failed retired].freeze

  belongs_to :app
  has_many :runtime_instances, dependent: :restrict_with_error

  before_validation :copy_defaults_from_app
  after_create :record_creation_event

  validates :image_reference, :port, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
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

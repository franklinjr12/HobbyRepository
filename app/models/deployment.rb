class Deployment < ApplicationRecord
  STATUSES = %w[created deploying deployed failed retired].freeze

  belongs_to :app
  has_many :runtime_instances, dependent: :restrict_with_error

  before_validation :copy_defaults_from_app
  after_create :record_creation_event

  validates :image_reference, :port, :health_check_path, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :port, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 }

  def mark_current!
    transaction do
      app.deployments.where.not(id: id).find_each { |deployment| deployment.update!(current: false) }
      update!(current: true, deployed_at: deployed_at || Time.current)
    end
  end

  private

  def copy_defaults_from_app
    return unless app

    self.image_reference = app.image_reference if image_reference.blank?
    self.port ||= app.internal_port
    self.health_check_path = app.health_check_path if health_check_path.blank?
  end

  def record_creation_event
    app.record_event!(
      "deployment.created",
      "Deployment #{id} was created",
      metadata: {
        deployment_id: id,
        image_reference: image_reference,
        port: port,
        current: current
      }
    )
  end
end

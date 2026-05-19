class RuntimeInstance < ApplicationRecord
  STATUSES = %w[starting running stopped crashed missing].freeze

  belongs_to :app
  belongs_to :node
  belongs_to :deployment, optional: true
  has_many :app_logs, dependent: :destroy

  before_validation :assign_node_from_app
  before_validation :assign_deployment_from_app

  validates :status, inclusion: { in: STATUSES }
  validates :container_id, uniqueness: true, allow_blank: true
  validates :exit_code, numericality: { only_integer: true }, allow_nil: true
  validates :internal_port,
            numericality: { only_integer: true, greater_than: 0, less_than: 65_536 },
            allow_nil: true

  def internal_target_ready?
    internal_host.present? && internal_port.present?
  end

  def log_label
    container_id.presence || "Runtime ##{id}"
  end

  private

  def assign_node_from_app
    self.node ||= app&.node
  end

  def assign_deployment_from_app
    self.deployment ||= app&.current_deployment
  end
end
